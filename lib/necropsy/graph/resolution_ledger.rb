# frozen_string_literal: true

module Necropsy
  module Graph
    class ResolutionLedger
      include ResolutionStore

      alias stored_resolution_records resolution_records
      alias stored_resolution_status_counts resolution_status_counts
      alias stored_call_sites_resolving_definition call_sites_resolving_definition
      alias stored_resolution_conflicts resolution_conflicts
      alias stored_resolution_issues resolution_issues
      alias stored_register_result_resolutions register_result_resolutions
      alias stored_refresh_resolution_derived_state refresh_resolution_derived_state

      def initialize(graph)
        @graph = graph
        initialize_resolution_store
      end

      def bind(graph)
        @graph = graph
      end

      def duplicate_with(memo)
        return memo.fetch(self) if memo.key?(self)

        copy = dup
        memo[self] = copy
        instance_variables.each do |name|
          next if name == :@graph

          copy.instance_variable_set(name, yield(instance_variable_get(name), memo))
        end
        copy
      end

      def resolution_records(call_site_id = nil)
        stored_resolution_records(call_site_id)
      end

      def resolution_status_counts
        stored_resolution_status_counts
      end

      def call_sites_resolving_definition(definition_id)
        stored_call_sites_resolving_definition(definition_id)
      end

      def resolution_conflicts
        stored_resolution_conflicts
      end

      def resolution_issues
        stored_resolution_issues
      end

      def register_result_resolutions(result, refresh: true)
        stored_register_result_resolutions(result, refresh: refresh)
      end

      def refresh_resolution_derived_state
        stored_refresh_resolution_derived_state
      end

      private

      def store
        @graph.store
      end

      def nodes
        @graph.nodes
      end

      def call_sites
        @graph.call_sites
      end

      def observation
        @graph.observation
      end

      def evidence_record(evidence_id)
        @graph.evidence_record(evidence_id)
      end

      def add_blocker(blocker)
        @graph.add_blocker(blocker)
      end

      def remove_blockers_matching(...)
        @graph.send(:remove_blockers_matching, ...)
      end
    end
  end
end
