# frozen_string_literal: true

require 'json'
require 'yaml'

module Necropsy
  class Report
    SCHEMA_VERSION = 2
    FINGERPRINT_COMPATIBILITY = {
      'fingerprint' => 'legacy logical symbol fingerprint retained for compatibility',
      'physical_fingerprint' => 'physical definition fingerprint for baselines and definition-level matching'
    }.freeze

    attr_reader :root, :graph, :findings, :reachability, :project, :source_snapshot

    def initialize(root:, graph:, findings:, reachability: nil, report_include_paths: [], report_exclude_paths: [],
                   project: nil, source_snapshot: nil)
      @root = root
      @graph = graph
      @findings = findings.sort_by do |finding|
        [finding.node.file, finding.node.line, finding.node.id, finding.node.definition_id]
      end
      @reachability = reachability
      @project = project
      @source_snapshot = source_snapshot
      @report_include_paths = report_include_paths
      @report_exclude_paths = report_exclude_paths
    end

    def dead_methods(min_confidence: :low)
      reported_findings.select { |finding| finding.at_least?(min_confidence) }
    end

    def blocked_methods
      reported_findings.select { |finding| finding.classification == :blocked }
    end

    def to_h(include_graph: false)
      payload = {
        'schema_version' => SCHEMA_VERSION,
        'compatibility' => { 'finding_fingerprints' => FINGERPRINT_COMPATIBILITY },
        'root' => root,
        'summary' => summary,
        'findings' => reported_findings.map(&:to_h)
      }
      payload['diagnostics'] = diagnostics unless diagnostics.empty?
      payload['graph'] = graph.to_h if include_graph
      payload
    end

    def to_json(state = nil, include_graph: false)
      payload = to_h(include_graph: include_graph)
      return JSON.pretty_generate(payload) unless state

      payload.to_json(state)
    end

    def to_yaml(include_graph: false)
      to_h(include_graph: include_graph).to_yaml
    end

    def summary
      grouped = reported_findings.group_by(&:classification)
      {
        'nodes' => graph.nodes.length,
        'edges' => graph.edges.length,
        'entry_points' => graph.entry_points.length,
        'incomplete_files' => graph.incomplete_files.length,
        'findings' => reported_findings.length,
        'unreachable' => grouped.fetch(:unreachable, []).length,
        'unused' => grouped.fetch(:unused, []).length,
        'blocked' => grouped.fetch(:blocked, []).length,
        'test_only_reachable' => grouped.fetch(:test_only_reachable, []).length
      }
    end

    def diagnostics
      result = {}
      dynamic = graph.dynamic_evidence_diagnostic
      result['dynamic_evidence'] = dynamic if dynamic
      definition_resolution = graph.observation['definition_resolution']
      result['definition_resolution'] = definition_resolution if definition_resolution
      reference_barrier = graph.observation['non_ruby_reference_barrier']
      result['non_ruby_reference_barrier'] = reference_barrier if reference_barrier
      result['source_incompleteness'] = graph.source_incompleteness if graph.incomplete_files.any?
      result['analysis_scope'] = graph.scope_diagnostics unless graph.scope_diagnostics.empty?
      result
    end

    private

    attr_reader :report_include_paths, :report_exclude_paths

    def reported_findings
      @reported_findings ||= findings.select do |finding|
        included_in_report?(finding.node.file) && !excluded_from_report?(finding.node.file)
      end
    end

    def included_in_report?(path)
      report_include_paths.empty? || report_include_paths.any? { |pattern| path_matches?(pattern, path) }
    end

    def excluded_from_report?(path)
      report_exclude_paths.any? { |pattern| path_matches?(pattern, path) }
    end

    def path_matches?(pattern, path)
      File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
        File.fnmatch?(File.join(pattern, '**', '*'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
  end
end
