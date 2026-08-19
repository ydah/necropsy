# frozen_string_literal: true

require 'json'

module Necropsy
  module Reporters
    class Ndjson
      def initialize(report)
        @report = report
      end

      def each
        return enum_for(__method__) unless block_given?

        yield record('report', report.to_h(include_graph: false))
        graph = report.graph
        {
          'node' => graph.nodes.values,
          'call_site' => graph.call_sites,
          'edge' => graph.edges,
          'edge_relation' => graph.edge_relations,
          'evidence' => graph.evidence_records,
          'entry_point' => graph.entry_points,
          'class_info' => graph.class_infos.values,
          'profile' => graph.profiles,
          'resolution' => graph.resolution_records,
          'blocker' => graph.blockers,
          'source_error' => graph.source_errors
        }.each do |record_type, records|
          records.each { |item| yield record(record_type, item.to_h) }
        end
        yield record('graph_metadata', {
                       'edge_projection' => 'conservative',
                       'instantiated_classes' => graph.instantiated_classes.to_a.sort,
                       'file_statuses' => graph.file_statuses.transform_values(&:to_s),
                       'source_domains' => graph.source_domains.transform_values(&:to_s),
                       'scope_diagnostics' => graph.scope_diagnostics,
                       'observation' => graph.observation
                     })
      end

      private

      attr_reader :report

      def record(record_type, data)
        JSON.generate('schema' => 'necropsy.graph.ndjson.v1', 'record' => record_type, 'data' => data)
      end
    end
  end
end
