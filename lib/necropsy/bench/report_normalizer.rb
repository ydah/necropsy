# frozen_string_literal: true

require 'json'

module Necropsy
  module Bench
    class ReportNormalizer
      VERSION = 1

      def initialize(report:, corpus:)
        @report = report
        @corpus = corpus
      end

      def call
        {
          'schema_version' => VERSION,
          'corpus' => corpus,
          'metrics' => metrics,
          'states' => state_counts,
          'findings' => normalized_findings
        }
      end

      def dump
        "#{JSON.pretty_generate(call)}\n"
      end

      private

      attr_reader :report, :corpus

      def metrics
        {
          'nodes' => report.graph.nodes.length,
          'definitions' => report.graph.method_nodes.length,
          'call_sites' => report.graph.call_sites.length,
          'edges' => report.graph.edges.length,
          'findings' => report.findings.length
        }
      end

      def state_counts
        report.findings.group_by(&:classification).transform_values(&:length).transform_keys(&:to_s).sort.to_h
      end

      def normalized_findings
        report.findings.sort_by { |finding| finding.node.id }.map do |finding|
          {
            'id' => finding.node.id,
            'path' => finding.node.file,
            'line' => finding.node.line,
            'state' => finding.classification.to_s,
            'confidence' => finding.confidence.to_s,
            'reasons' => finding.reasons.map(&:to_s).sort
          }
        end
      end
    end
  end
end
