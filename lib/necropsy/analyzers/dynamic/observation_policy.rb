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

          normalized = observation.merge(
            'schema_version' => payload.fetch('schema_version', 1),
            'positive_evidence_policy' => 'alive_only',
            'source_revision_status' => revision ? 'provided_unverified' : 'unknown',
            'source_revision_policy' => 'accepted_for_liveness_only'
          )
          revision ? normalized.merge('source_revision' => revision) : normalized
        end

        def evidence_scope(observation)
          declared_scope = observation['scope']
          declared_scope = {} unless declared_scope.is_a?(Hash)
          declared_scope = declared_scope.reject do |key, _value|
            %w[revision source_revision].include?(key.to_s)
          end
          selectors = {
            'revision' => observation['source_revision'],
            'environment' => observation['environment'],
            'collector' => observation['collector']
          }.compact
          declared_scope.merge(selectors)
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
