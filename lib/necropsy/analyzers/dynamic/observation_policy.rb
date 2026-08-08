# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Dynamic
      module ObservationPolicy
        module_function

        def metadata(payload = nil, expected_revision: nil, **keyword_payload)
          payload ||= keyword_payload
          observation = payload['observation']
          observation = {} unless observation.is_a?(Hash)
          schema_version = Integer(payload.fetch('schema_version', 1), exception: false)
          raise Error, 'Dynamic observation schema version must be 1 or 2' unless [1, 2].include?(schema_version)

          revision = source_revision(payload, observation)

          status = source_revision_status(payload, observation, revision, expected_revision)
          normalized = observation.merge(
            'schema_version' => schema_version,
            'positive_evidence_policy' => 'alive_only',
            'source_revision_status' => status,
            'source_revision_policy' => 'accepted_for_liveness_only'
          )
          normalized = normalized.merge('source_revision' => revision) if revision
          normalized = normalized.merge('expected_source_revision' => expected_revision) if expected_revision
          return normalized unless schema_version == 2

          collector = payload['collector']
          collector = {} unless collector.is_a?(Hash)
          source = payload['source']
          source = {} unless source.is_a?(Hash)
          scope = payload['scope']
          scope = {} unless scope.is_a?(Hash)
          quality = payload['quality']
          quality = {} unless quality.is_a?(Hash)
          normalized.merge(
            'collector_name' => collector['name'] || payload['collector_name'],
            'collector_version' => collector['version'] || payload['collector_version'],
            'source_metadata' => source,
            'environment' => scope['environment'] || observation['environment'],
            'sample_unit' => scope['sample_unit'] || observation['sample_unit'],
            'sample_rate' => scope['sample_rate'] || observation['sample_rate'],
            'quality' => {
              'dropped_events' => quality.fetch('dropped_events', 0),
              'overflowed' => quality.fetch('overflowed', false)
            }
          ).compact
        end

        def compatible_merge(left, right)
          return left.merge(right) unless left.is_a?(Hash) && right.is_a?(Hash)

          %w[source_revision source_revision_status environment collector_name collector_version].each do |key|
            next if left[key].nil? || right[key].nil? || left[key] == right[key]

            raise Error, "Dynamic observation #{key} is incompatible"
          end
          left.merge(right)
        end

        def evidence_scope(observation)
          declared_scope = observation['scope']
          declared_scope = {} unless declared_scope.is_a?(Hash)
          declared_scope = declared_scope.reject do |key, _value|
            %w[revision source_revision].include?(key.to_s)
          end
          selectors = {
            'revision' => observation['source_revision'],
            'source_revision_status' => observation['source_revision_status'],
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

        def source_revision_status(payload, observation, revision, expected_revision)
          stale = payload['stale'] || observation['stale'] || payload['source_revision_status'] == 'stale'
          return 'stale' if stale
          return 'unknown' unless revision
          return 'provided_unverified' unless expected_revision

          revision.to_s == expected_revision.to_s ? 'match' : 'mismatch'
        end
        private_class_method :source_revision_status
      end
    end
  end
end
