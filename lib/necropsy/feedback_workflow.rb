# frozen_string_literal: true

require 'json'
require 'yaml'

module Necropsy
  class FeedbackWorkflow
    def initialize(static_report:, observed_artifact:, max_fixtures: RuntimeFeedback::DEFAULT_FIXTURE_LIMIT)
      @static_report = load_artifact(static_report)
      @observed_artifact = load_artifact(observed_artifact)
      @max_fixtures = max_fixtures
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
        source = @static_report['graph'] || @static_report
        explicit = source['static_targets'] || @static_report['static_targets']
        if explicit
          normalize_static_targets(explicit)
        else
          Array(source['resolutions']).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |record, result|
            resolution = record['resolution'] || record
            call_site_id = resolution['call_site_id']
            next if call_site_id.to_s.empty?

            result[call_site_id].concat(Array(resolution['target_definition_ids']))
          end.transform_values { |targets| targets.map(&:to_s).uniq.sort }
        end
      end
    end

    def observed_targets
      source = @observed_artifact
      values = if source.is_a?(Array)
                 source
               else
                 source['observed_targets'] || source['targets'] || source['runtime_targets'] || source
               end
      raise Error, 'Observed artifact must contain an array of observed targets' unless values.is_a?(Array)

      values
    end

    def normalize_static_targets(value)
      raise Error, 'Static target artifact must contain a mapping' unless value.is_a?(Hash)

      value.transform_keys(&:to_s).transform_values { |targets| Array(targets).map(&:to_s).uniq.sort }
    end

    def load_artifact(path)
      contents = File.read(File.expand_path(path))
      JSON.parse(contents)
    rescue JSON::ParserError
      YAML.safe_load(contents, aliases: false) || {}
    rescue SystemCallError, Psych::Exception => e
      raise Error, "Could not read feedback artifact #{path}: #{e.message}"
    end
  end
end
