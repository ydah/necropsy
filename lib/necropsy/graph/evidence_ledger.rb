# frozen_string_literal: true

module Necropsy
  module Graph
    class EvidenceLedger
      include EvidenceStore

      alias stored_evidence_records evidence_records
      alias stored_evidence_record evidence_record
      alias stored_evidence_collisions evidence_collisions
      alias stored_projected_evidence_records projected_evidence_records
      alias stored_projected_evidence_ids projected_evidence_ids

      def initialize(graph)
        @graph = graph
        initialize_evidence_store
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

      def evidence_records
        stored_evidence_records
      end

      def evidence_record(evidence_id)
        stored_evidence_record(evidence_id)
      end

      def evidence_collisions
        stored_evidence_collisions
      end

      def normalize_projection(projection)
        EvidenceStore.normalize_projection(projection)
      end

      def projected_evidence_records(evidence_ids, projection:, scope: nil)
        stored_projected_evidence_records(evidence_ids, projection: projection, scope: scope)
      end

      def projected_evidence_ids(evidence_ids, projection:, scope: nil)
        stored_projected_evidence_ids(evidence_ids, projection: projection, scope: scope)
      end

      def register(evidence, domain: :runtime, canonical_payload: nil)
        send(:register_evidence, evidence, domain: domain, canonical_payload: canonical_payload)
      end

      def with_identity(evidence)
        send(:evidence_with_identity, evidence)
      end

      def payload_registered?(evidence, canonical_payload: nil)
        send(:evidence_payload_registered?, evidence, canonical_payload: canonical_payload)
      end

      private

      def store
        @graph.store
      end

      def observation
        @graph.observation
      end

      def add_blocker(blocker)
        @graph.add_blocker(blocker)
      end

      def remove_blockers_matching(...)
        @graph.send(:remove_blockers_matching, ...)
      end

      def rebuild_incoming_edges
        @graph.send(:rebuild_incoming_edges)
      end
    end
  end
end
