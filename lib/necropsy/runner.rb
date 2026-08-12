# frozen_string_literal: true

require 'json'

module Necropsy
  class Runner
    ANALYZER_ERROR_MESSAGE_BYTES = 500
    INVALID_BLOCKER_KINDS = %i[
      analyzer_failure blocker_invalid evidence_collision rails_route_health resolution_invalid unsound_rta_pruning
    ].freeze
    DEGRADED_BLOCKER_KINDS = %i[
      reference_scan_incomplete reference_scope_incomplete source_discovery_incomplete
    ].freeze

    attr_reader :root, :config, :analyzers, :ignored_reference_paths, :clock

    def initialize(root:, config_path: nil, analyzers: nil, ignored_reference_paths: [], as_of: nil)
      @root = File.expand_path(root)
      @config = Configuration.load(root: @root, path: config_path)
      @analyzers = analyzers
      @ignored_reference_paths = ignored_reference_paths
      @clock = Clock.new(as_of: as_of)
    end

    def analyze(rta_pruning: config.rta_pruning, profile: false)
      rta_pruning = normalize_rta_pruning(rta_pruning)
      profiler = profile ? PerformanceProfiler.new : nil
      project = measure_phase(profiler, 'project') { Project.new(root: root, config: config) }
      source_snapshot = measure_phase(profiler, 'source_snapshot') { project.source_snapshot }
      graph = measure_phase(profiler, 'scan') do
        CallGraph.new(project.scan_result, ambiguity_limit: config.ambiguity_limit)
      end
      project.scope_blockers.each { |blocker| graph.add_blocker(blocker) }
      graph.add_blocker(unsound_rta_pruning_blocker) if rta_pruning == :legacy
      rta_results = []

      measure_phase(profiler, 'entry_points') { apply_entry_points(graph, project) }
      configured_analyzers.each do |configured_analyzer|
        analyzer_name = configured_analyzer.profile.name
        analyzer_profile, result = measure_phase(profiler, "analyzer:#{analyzer_name}") do
          run_analyzer(graph, project, configured_analyzer, rta_pruning)
        end
        rta_results << result if analyzer_profile&.name == :rta && result
      end
      graph.refresh_derived_state
      measure_phase(profiler, 'reachability') do
        rta_results.each { |result| graph.reconcile_rta_result(result) } if rta_pruning == :legacy
      end

      reachability = measure_phase(profiler, 'reachability_engine') { Reachability::Engine.new(graph).call }
      LoadGraph.record_unrooted_units(graph: graph, reachability: reachability)
      findings = measure_phase(profiler, 'scoring') do
        scorer = Confidence::Scorer.new(graph: graph, reachability: reachability, project: project, clock: clock)
        scorer.findings
      end
      barrier_matches = measure_phase(profiler, 'reference_barrier') do
        ReferenceBarrier.new(
          graph: graph,
          project: project,
          ignored_paths: ignored_reference_paths
        ).apply(findings)
      end
      if barrier_matches.positive?
        findings = Confidence::Scorer.new(
          graph: graph, reachability: reachability, project: project, clock: clock
        ).findings
      end
      final_source_snapshot = measure_phase(profiler, 'source_snapshot_verification') { project.fresh_source_snapshot }
      analysis_health = build_analysis_health(graph, source_snapshot, final_source_snapshot)
      source_snapshot = verified_source_snapshot(source_snapshot, final_source_snapshot)
      performance = profiler&.report(
        counts: graph.performance_counts,
        report_index_size_bytes: report_index_size_bytes(graph)
      )
      Report.new(
        root: root,
        graph: graph,
        findings: findings,
        reachability: reachability,
        project: project,
        source_snapshot: source_snapshot,
        analysis_health: analysis_health,
        report_include_paths: config.report_include_paths,
        report_exclude_paths: config.report_exclude_paths,
        performance_profile: performance
      )
    end

    private

    def build_analysis_health(graph, initial_snapshot, final_snapshot)
      reasons = snapshot_health_reasons(initial_snapshot, final_snapshot)
      graph.blockers.each do |blocker|
        severity = blocker_health_severity(blocker)
        next unless severity

        reasons << blocker_health_reason(blocker, severity)
      end
      AnalysisHealth.from_reasons(reasons.uniq { |reason| BoundedCanonicalizer.dump(reason) })
    end

    def snapshot_health_reasons(initial_snapshot, final_snapshot)
      snapshots = { 'initial' => initial_snapshot, 'final' => final_snapshot }
      unavailable = snapshots.filter_map do |phase, snapshot|
        next if snapshot['status'] == 'complete'

        { 'phase' => phase, 'reason' => snapshot['reason'], 'details' => snapshot.except('sha256') }
      end
      return [{ 'severity' => 'invalid', 'code' => 'source_snapshot_unavailable', 'snapshots' => unavailable }] if unavailable.any?
      return [] if initial_snapshot['sha256'] == final_snapshot['sha256']

      [{
        'severity' => 'invalid',
        'code' => 'source_changed_during_analysis',
        'initial_sha256' => initial_snapshot['sha256'],
        'final_sha256' => final_snapshot['sha256']
      }]
    end

    def blocker_health_severity(blocker)
      return :invalid if blocker.kind == :parse_incomplete && blocker.caller_domain == :runtime
      return :invalid if INVALID_BLOCKER_KINDS.include?(blocker.kind)

      :degraded if DEGRADED_BLOCKER_KINDS.include?(blocker.kind)
    end

    def blocker_health_reason(blocker, severity)
      metadata = blocker.metadata
      {
        'severity' => severity.to_s,
        'code' => blocker.kind.to_s,
        'message' => blocker.reason,
        'source' => blocker.source.respond_to?(:to_h) ? blocker.source.to_h : blocker.source.to_s,
        'file' => metadata['file'] || metadata[:file],
        'line' => metadata['line'] || metadata[:line]
      }.compact
    end

    def verified_source_snapshot(initial_snapshot, final_snapshot)
      status = if initial_snapshot['status'] != 'complete' || final_snapshot['status'] != 'complete'
                 'unavailable'
               elsif initial_snapshot['sha256'] == final_snapshot['sha256']
                 'match'
               else
                 'mismatch'
               end
      initial_snapshot.merge(
        'verification' => {
          'status' => status,
          'final_status' => final_snapshot['status'],
          'final_sha256' => final_snapshot['sha256']
        }
      )
    end

    def measure_phase(profiler, name, &block)
      return block.call unless profiler

      profiler.measure(name, &block)
    end

    def report_index_size_bytes(graph)
      node_bytes = graph.nodes.values.sum { |node| JSON.generate(node.to_h).bytesize }
      call_site_bytes = graph.call_sites.sum { |site| JSON.generate(site.to_h).bytesize }
      edge_bytes = graph.edges.sum { |edge| JSON.generate(edge.to_h).bytesize }
      node_bytes + call_site_bytes + edge_bytes
    end

    def normalize_rta_pruning(value)
      mode = value.to_s
      return mode.to_sym if Configuration::RTA_PRUNING_MODES.include?(mode)

      raise Error, "RTA pruning must be one of: #{Configuration::RTA_PRUNING_MODES.join(', ')}"
    end

    def analyzer_for_pruning(analyzer, mode)
      return analyzer unless analyzer.is_a?(Analyzers::Static::RTA)

      configured = analyzer.with_pruning(mode)
      return configured unless mode == :rank_only

      configured.without_redundant_edges
    end

    def run_analyzer(graph, project, configured_analyzer, rta_pruning)
      analyzer = analyzer_for_pruning(configured_analyzer, rta_pruning)
      profile = analyzer.profile
      raise TypeError, "#{analyzer.class} returned an invalid analyzer profile" unless profile.is_a?(AnalyzerProfile)

      graph.add_profile(profile)
      result = analyzer.analyze(graph, project)
      result = Analyzers::LegacyResultAdapter.new(graph: graph, profile: profile).adapt(result)
      validate_result_capabilities!(analyzer, result)
      graph.apply_result(result, refresh: false)
      [profile, result]
    rescue StandardError => e
      graph.add_blocker(analyzer_failure_blocker(analyzer || configured_analyzer, profile, e))
      [profile, nil]
    end

    def analyzer_failure_blocker(analyzer, profile, error)
      analyzer_name = profile&.name&.to_s || analyzer.class.name
      error_message = safe_error_message(error)
      Blocker.new(
        kind: :analyzer_failure,
        scope_kind: :global,
        scope_value: '*',
        source: analyzer_name,
        reason: "Analyzer #{analyzer_name} failed: #{error.class}: #{error_message}",
        suggested_action: :fix_analyzer,
        metadata: {
          'analyzer' => analyzer_name,
          'analyzer_class' => analyzer.class.name,
          'caller_domain' => 'runtime',
          'error_class' => error.class.name,
          'error_message' => error_message
        }
      )
    end

    def validate_result_capabilities!(analyzer, result)
      complete = Array(result.resolutions).any? { |record| record.resolution.status == :complete }
      return unless complete
      return if Array(analyzer.capabilities).map(&:to_sym).include?(:complete_resolution)

      raise TypeError, "#{analyzer.class} emitted complete resolution without complete_resolution capability"
    end

    def unsound_rta_pruning_blocker
      Blocker.new(
        kind: :unsound_rta_pruning,
        scope_kind: :global,
        scope_value: '*',
        source: :configuration,
        reason: 'Legacy RTA pruning can remove reachable targets without complete allocation evidence',
        suggested_action: :use_rank_only_rta,
        metadata: { 'caller_domain' => 'runtime', 'rta_pruning' => 'legacy' }
      )
    end

    def safe_error_message(error)
      message = error.message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      return message if message.bytesize <= ANALYZER_ERROR_MESSAGE_BYTES

      "#{message.byteslice(0, ANALYZER_ERROR_MESSAGE_BYTES).to_s.scrub}\u2026"
    rescue StandardError, SystemStackError
      'unavailable'
    end

    def apply_entry_points(graph, project)
      EntryPoints::Plain.new.apply(graph, project)
      EntryPoints::Rails.new.apply(graph, project)
      EntryPoints::Test.new.apply(graph, project)
      graph.entrypoint_hints.each do |entry|
        graph.add_entry_point(
          entry.node_id,
          entry.reason,
          domain: entry.domain,
          evidence: entry.evidence
        )
      end
      WorldPolicy.new(graph: graph, project: project).apply
    end

    def configured_analyzers
      return analyzers if analyzers

      static = config.static_analyzers.filter_map do |name|
        case name
        when 'name_resolution'
          Analyzers::Static::NameResolution.new
        when 'cha'
          Analyzers::Static::CHA.new
        when 'rta'
          Analyzers::Static::RTA.new
        else
          raise Error, "Unknown static analyzer: #{name}"
        end
      end

      dynamic = []
      coverage_config = config.dynamic_config(:coverage)
      dynamic << Analyzers::Dynamic::CoverageImporter.new(coverage_config) if coverage_config['source']
      coverband_config = config.dynamic_config(:coverband)
      dynamic << Analyzers::Dynamic::CoverbandImporter.new(coverband_config) if coverband_config['source']
      trace_point_config = config.dynamic_config(:trace_point)
      dynamic << Analyzers::Dynamic::TracePointImporter.new(trace_point_config) if trace_point_config['source']

      static + dynamic + custom_analyzers
    end

    def custom_analyzers
      config.custom_analyzers.map do |entry|
        class_name, required_path = custom_analyzer_definition(entry)
        require_custom_analyzer(required_path) if required_path
        constantize(class_name).new
      rescue NameError => e
        raise Error, "Could not load custom analyzer #{class_name}: #{e.message}"
      rescue LoadError => e
        raise Error, "Could not require custom analyzer #{class_name}: #{e.message}"
      end
    end

    def custom_analyzer_definition(entry)
      [entry.fetch('class'), entry['require']]
    end

    def require_custom_analyzer(path)
      expanded = File.expand_path(path, root)
      expanded = "#{expanded}.rb" if !File.file?(expanded) && File.file?("#{expanded}.rb")
      File.file?(expanded) ? require(expanded) : require(path)
    end

    def constantize(class_name)
      class_name.split('::').reduce(Object) { |constant, name| constant.const_get(name) }
    end
  end
end
