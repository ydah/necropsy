# frozen_string_literal: true

require_relative 'artifact_loader'

module Necropsy
  class FeedbackWorkflow
    def initialize(static_report:, observed_artifact:, max_fixtures: RuntimeFeedback::DEFAULT_FIXTURE_LIMIT)
      @static_report = ArtifactLoader.load_mapping(static_report, label: 'Static feedback report')
      validate_static_report!
      @observed_artifact = ArtifactLoader.load(observed_artifact, label: 'Observed feedback artifact')
      @max_fixtures = normalize_max_fixtures(max_fixtures)
      observed_targets
    end

    def compare
      RuntimeFeedback.new(
        static_targets: static_targets,
        observed_targets: observed_targets,
        max_fixtures: @max_fixtures
      ).call
    end

    def export_fixtures(path)
      feedback.write_fixture_candidates(path)
    end

    def verify(fail_on_missing_static_target: false)
      result = compare
      missing = result.fetch('missing_static_targets')
      result.merge(
        'verification' => {
          'passed' => !fail_on_missing_static_target || missing.empty?,
          'fail_on_missing_static_target' => fail_on_missing_static_target,
          'missing_static_target_count' => missing.length
        }
      )
    end

    private

    def feedback
      @feedback ||= RuntimeFeedback.new(
        static_targets: static_targets,
        observed_targets: observed_targets,
        max_fixtures: @max_fixtures
      )
    end

    def static_targets
      @static_targets ||= begin
        source = @static_report['graph'].is_a?(Hash) ? @static_report['graph'] : {}
        explicit = @static_report['static_targets'] || source['static_targets']
        if explicit
          normalize_static_targets(explicit)
        else
          source.fetch('resolutions').each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |record, result|
            resolution = record['resolution'] || record
            call_site_id = resolution['call_site_id']
            next if call_site_id.to_s.empty?

            result[call_site_id].concat(Array(resolution['target_definition_ids']))
          end.transform_values { |targets| targets.map(&:to_s).uniq.sort }
        end
      end
    end

    def observed_targets
      @observed_targets ||= begin
        values = observed_target_values
        raise Error, 'Observed artifact must contain an array of observed targets' unless values.is_a?(Array)

        values.each_with_index { |target, index| validate_observed_target!(target, index) }
        values
      end
    end

    def observed_target_values
      source = @observed_artifact
      return source if source.is_a?(Array)
      return unless source.is_a?(Hash)

      source['observed_targets'] || source['targets'] || source['runtime_targets'] || source
    end

    def validate_observed_target!(target, index)
      raise Error, "Observed target #{index} must be a mapping" unless target.is_a?(Hash)

      call_site_id = target['call_site_id'] || target[:call_site_id]
      target_definition_id = target['target_definition_id'] || target['target_id'] ||
                             target[:target_definition_id] || target[:target_id]
      raise Error, "Observed target #{index} must include call_site_id" unless valid_identifier?(call_site_id)
      raise Error, "Observed target #{index} must include target_definition_id" unless
        valid_identifier?(target_definition_id)
    end

    def normalize_max_fixtures(value)
      count = Integer(value)
      raise Error, 'max_fixtures must be a non-negative integer' if count.negative?

      count
    rescue ArgumentError, TypeError
      raise Error, 'max_fixtures must be a non-negative integer'
    end

    def normalize_static_targets(value)
      raise Error, 'Static target artifact must contain a mapping' unless value.is_a?(Hash)

      value.transform_keys(&:to_s).transform_values do |targets|
        raise Error, 'Static target entries must contain arrays' unless targets.is_a?(Array)

        targets.map do |target|
          raise Error, 'Static target IDs must be scalar non-empty IDs' unless valid_identifier?(target)

          target.to_s
        end.uniq.sort
      end
    end

    def validate_static_report!
      graph = @static_report['graph']
      raise Error, 'Static feedback report graph must be a mapping' if graph && !graph.is_a?(Hash)

      explicit = @static_report['static_targets'] || graph&.[]('static_targets')
      resolutions = graph&.[]('resolutions')
      raise Error, 'Static feedback report must include static_targets or graph.resolutions' unless
        explicit.is_a?(Hash) || resolutions.is_a?(Array)

      normalize_static_targets(explicit) if explicit

      return unless resolutions

      resolutions.each do |record|
        raise Error, 'Static feedback report resolutions must contain mappings' unless record.is_a?(Hash)

        resolution = record['resolution'] || record
        raise Error, 'Static feedback report resolution must be a mapping' unless resolution.is_a?(Hash)

        call_site_id = resolution['call_site_id']
        raise Error, 'Static feedback report call_site_id must be a scalar non-empty ID' unless
          valid_identifier?(call_site_id)

        target_ids = resolution['target_definition_ids']
        if target_ids && (!target_ids.is_a?(Array) || target_ids.any? { |target| !valid_identifier?(target) })
          raise Error, 'Static feedback report target_definition_ids must be an array of scalar IDs'
        end
      end
    end

    def valid_identifier?(value)
      (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.empty?
    end
  end
end
