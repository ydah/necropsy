# frozen_string_literal: true

require 'json'
require 'yaml'

module Necropsy
  class Report
    attr_reader :root, :graph, :findings, :reachability

    def initialize(root:, graph:, findings:, reachability: nil, report_include_paths: [], report_exclude_paths: [])
      @root = root
      @graph = graph
      @findings = findings.sort_by { |finding| [finding.node.file, finding.node.line, finding.node.id] }
      @reachability = reachability
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
        'findings' => reported_findings.length,
        'unreachable' => grouped.fetch(:unreachable, []).length,
        'unused' => grouped.fetch(:unused, []).length,
        'blocked' => grouped.fetch(:blocked, []).length,
        'test_only_reachable' => grouped.fetch(:test_only_reachable, []).length
      }
    end

    def diagnostics
      dynamic = graph.dynamic_evidence_diagnostic
      dynamic ? { 'dynamic_evidence' => dynamic } : {}
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
