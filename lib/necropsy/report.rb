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

    def to_h(include_graph: true)
      payload = {
        'root' => root,
        'summary' => summary,
        'findings' => findings.map(&:to_h)
      }
      payload['graph'] = graph.to_h if include_graph
      payload
    end

    def to_json(state = nil, include_graph: true)
      payload = to_h(include_graph: include_graph)
      return JSON.pretty_generate(payload) unless state

      payload.to_json(state)
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
