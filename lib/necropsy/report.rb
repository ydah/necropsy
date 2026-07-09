# frozen_string_literal: true

require 'json'
require 'yaml'

module Necropsy
  class Report
    attr_reader :root, :graph, :findings

    def initialize(root:, graph:, findings:)
      @root = root
      @graph = graph
      @findings = findings
    end

    def dead_methods(min_confidence: :low)
      findings.select { |finding| finding.at_least?(min_confidence) }
    end

    def to_h
      {
        'root' => root,
        'summary' => summary,
        'findings' => findings.map(&:to_h),
        'graph' => graph.to_h
      }
    end

    def to_json(*)
      JSON.pretty_generate(to_h, *)
    end

    def to_yaml
      to_h.to_yaml
    end

    def summary
      grouped = findings.group_by(&:classification)
      {
        'nodes' => graph.nodes.length,
        'edges' => graph.edges.length,
        'entry_points' => graph.entry_points.length,
        'findings' => findings.length,
        'unreachable' => grouped.fetch(:unreachable, []).length,
        'unused' => grouped.fetch(:unused, []).length,
        'test_only_reachable' => grouped.fetch(:test_only_reachable, []).length
      }
    end
  end
end
