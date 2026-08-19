# frozen_string_literal: true

require 'json'
require_relative 'analyzer_execution'

module Necropsy
  class Runner
    ANALYZER_ERROR_MESSAGE_BYTES = AnalyzerExecution::ANALYZER_ERROR_MESSAGE_BYTES

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
      analyzer_execution = AnalyzerExecution.new(root: root, config: config, analyzers: analyzers)
      analyzer_execution.configured_analyzers.each do |configured_analyzer|
        analyzer_name = configured_analyzer.profile.name
        analyzer_profile, result = measure_phase(profiler, "analyzer:#{analyzer_name}") do
          analyzer_execution.run(
            graph: graph,
            project: project,
            configured_analyzer: configured_analyzer,
            rta_pruning: rta_pruning
          )
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
      analysis_health = AnalysisHealthBuilder.new(
        graph: graph,
        initial_snapshot: source_snapshot,
        final_snapshot: final_source_snapshot
      ).call
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
  end
end
