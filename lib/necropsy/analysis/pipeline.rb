# frozen_string_literal: true

require 'json'

module Necropsy
  module Analysis
    # Coordinates the ordered analysis phases without owning the public Runner API.
    class Pipeline
      def initialize(root:, config:, analyzers:, ignored_reference_paths:, clock:, rta_pruning:, profile:)
        @root = root
        @config = config
        @analyzers = analyzers
        @ignored_reference_paths = ignored_reference_paths
        @clock = clock
        @rta_pruning = normalize_rta_pruning(rta_pruning)
        @profiler = profile ? PerformanceProfiler.new : nil
      end

      def call
        project = measure_phase('project') { Project.new(root: root, config: config) }
        source_snapshot = measure_phase('source_snapshot') { project.source_snapshot }
        graph = scan(project)
        add_scope_blockers(graph, project)
        apply_entry_points(graph, project)
        rta_results = run_analyzers(graph, project)
        graph.refresh_derived_state
        reconcile_rta_results(graph, rta_results)

        reachability = measure_phase('reachability_engine') { Reachability::Engine.new(graph).call }
        LoadGraph.record_unrooted_units(graph: graph, reachability: reachability)
        findings = score(graph, reachability, project)
        findings = apply_reference_barrier(graph, project, reachability, findings)
        final_source_snapshot = measure_phase('source_snapshot_verification') { project.fresh_source_snapshot }

        build_report(
          graph: graph,
          project: project,
          reachability: reachability,
          findings: findings,
          source_snapshot: source_snapshot,
          final_source_snapshot: final_source_snapshot
        )
      end

      private

      attr_reader :root, :config, :analyzers, :ignored_reference_paths, :clock, :profiler, :rta_pruning

      def scan(project)
        measure_phase('scan') do
          CallGraph.new(project.scan_result, ambiguity_limit: config.ambiguity_limit)
        end
      end

      def add_scope_blockers(graph, project)
        project.scope_blockers.each { |blocker| graph.add_blocker(blocker) }
        graph.add_blocker(unsound_rta_pruning_blocker) if rta_pruning == :legacy
      end

      def apply_entry_points(graph, project)
        measure_phase('entry_points') do
          EntryPoints::Plain.new.apply(graph, project)
          EntryPoints::Rails.new.apply(graph, project)
          EntryPoints::Test.new.apply(graph, project)
          graph.entrypoint_hints.each do |entry|
            graph.add_entry_point(entry.node_id, entry.reason, domain: entry.domain, evidence: entry.evidence)
          end
          WorldPolicy.new(graph: graph, project: project).apply
        end
      end

      def run_analyzers(graph, project)
        rta_results = []
        execution = AnalyzerExecution.new(root: root, config: config, analyzers: analyzers)
        execution.configured_analyzers.each do |configured_analyzer|
          name = configured_analyzer.profile.name
          profile, result = measure_phase("analyzer:#{name}") do
            execution.run(
              graph: graph,
              project: project,
              configured_analyzer: configured_analyzer,
              rta_pruning: rta_pruning
            )
          end
          rta_results << result if profile&.name == :rta && result
        end
        rta_results
      end

      def reconcile_rta_results(graph, rta_results)
        measure_phase('reachability') do
          rta_results.each { |result| graph.reconcile_rta_result(result) } if rta_pruning == :legacy
        end
      end

      def score(graph, reachability, project)
        measure_phase('scoring') do
          Confidence::Scorer.new(graph: graph, reachability: reachability, project: project, clock: clock).findings
        end
      end

      def apply_reference_barrier(graph, project, reachability, findings)
        matches = measure_phase('reference_barrier') do
          ReferenceBarrier.new(graph: graph, project: project, ignored_paths: ignored_reference_paths).apply(findings)
        end
        return findings unless matches.positive?

        Confidence::Scorer.new(graph: graph, reachability: reachability, project: project, clock: clock).findings
      end

      def build_report(graph:, project:, reachability:, findings:, source_snapshot:, final_source_snapshot:)
        analysis_health = AnalysisHealthBuilder.new(
          graph: graph,
          initial_snapshot: source_snapshot,
          final_snapshot: final_source_snapshot
        ).call
        Report.new(
          root: root,
          graph: graph,
          findings: findings,
          reachability: reachability,
          project: project,
          source_snapshot: verified_source_snapshot(source_snapshot, final_source_snapshot),
          analysis_health: analysis_health,
          report_include_paths: config.report_include_paths,
          report_exclude_paths: config.report_exclude_paths,
          performance_profile: profiler&.report(
            counts: graph.performance_counts,
            report_index_size_bytes: report_index_size_bytes(graph)
          )
        )
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

      def measure_phase(name, &block)
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
    end
  end
end
