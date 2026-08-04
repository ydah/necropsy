# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Dynamic
      module ObservationPolicy
        module_function

        def metadata(payload)
          observation = payload['observation']
          observation = {} unless observation.is_a?(Hash)
          revision = source_revision(payload, observation)

          observation.merge(
            'schema_version' => payload.fetch('schema_version', 1),
            'positive_evidence_policy' => 'alive_only',
            'source_revision_status' => revision ? 'provided_unverified' : 'unknown',
            'source_revision_policy' => 'accepted_for_liveness_only'
          )
        end

        def source_revision(payload, observation)
          source = payload['source']
          source_revision = source['git_sha'] if source.is_a?(Hash)
          source_revision || payload['source_revision'] || observation['source_revision']
        end
        private_class_method :source_revision
      end
    end
  end
end
