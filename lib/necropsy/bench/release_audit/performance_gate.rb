# frozen_string_literal: true

module Necropsy
  module Bench
    class ReleaseAudit
      class PerformanceGate
        PROVENANCE_FIELDS = %w[ruby os command rss_kind rss_scope].freeze

        def initialize(config:, baseline:, current_summary:, current_provenance:)
          @config = config
          @baseline_document = baseline
          @baseline = baseline.fetch('corpora')
          @current = current_summary.fetch('corpora').to_h { |corpus| [corpus.fetch('id'), corpus] }
          @current_provenance = current_provenance
        end

        def call
          config.fetch('corpora').sort.to_h do |corpus|
            [corpus, compare_or_unavailable(corpus)]
          end
        end

        private

        attr_reader :config, :baseline_document, :baseline, :current, :current_provenance

        def compare_or_unavailable(corpus)
          return unavailable(provenance_error) if provenance_error

          baseline_result = baseline[corpus]
          current_run = current[corpus]
          return unavailable('baseline measurement unavailable') unless baseline_result
          return unavailable('current corpus was not generated') unless current_run&.fetch('status', 'generated') == 'generated'

          current_result = current_run['performance']
          return unavailable('current performance measurement unavailable') unless current_result
          return unavailable('current RSS measurement unavailable') unless rss_value(current_result)
          return unavailable('current RSS kind differs from the baseline') unless compatible_rss?(current_result)

          compare(corpus, baseline_result, current_result)
        rescue KeyError, ArgumentError, TypeError => e
          unavailable("invalid performance measurement: #{e.message}")
        end

        def compare(corpus, baseline_result, current_result)
          budget = config.fetch('performance')
          baseline_wall = Float(baseline_result.fetch('wall_time_seconds'))
          current_wall = Float(current_result.fetch('wall_time_seconds'))
          baseline_rss = Integer(baseline_result.fetch('rss_kb'))
          current_rss = rss_value(current_result)
          wall_limit = relative_limit(
            baseline_wall,
            ratio: budget.fetch('wall_time_ratio'),
            allowance: budget.fetch('wall_time_allowance_seconds'),
            absolute: budget.fetch('max_wall_time_seconds').fetch(corpus)
          )
          rss_limit = relative_limit(
            baseline_rss,
            ratio: budget.fetch('rss_ratio'),
            allowance: budget.fetch('rss_allowance_kb'),
            absolute: budget.fetch('max_rss_kb')
          )
          {
            'available' => true,
            'baseline_wall_time_seconds' => baseline_wall,
            'current_wall_time_seconds' => current_wall,
            'wall_time_limit_seconds' => wall_limit.round(6),
            'baseline_rss_kb' => baseline_rss,
            'current_rss_kb' => current_rss,
            'rss_limit_kb' => rss_limit.round,
            'rss_kind' => current_result['rss_kind'],
            'rss_scope' => current_result['rss_scope'],
            'passed' => current_wall <= wall_limit && current_rss <= rss_limit
          }
        end

        def provenance_error
          return @provenance_error if defined?(@provenance_error)

          @provenance_error = validate_provenance
        end

        def validate_provenance
          return 'baseline performance schema_version must be 1' unless baseline_document['schema_version'] == 1
          return 'current performance provenance schema_version must be 1' unless current_provenance['schema_version'] == 1
          unless baseline_document['git_ref'] == config.dig('baseline', 'git_ref')
            return 'baseline performance git_ref does not match the audit baseline'
          end

          baseline_environment = baseline_document['environment']
          current_environment = current_provenance['environment']
          return 'baseline performance environment is missing' unless baseline_environment.is_a?(Hash)
          return 'current performance environment is missing' unless current_environment.is_a?(Hash)

          mismatch = PROVENANCE_FIELDS.find do |field|
            baseline_environment[field].to_s != current_environment[field].to_s
          end
          "performance environment mismatch for #{mismatch}" if mismatch
        end

        def compatible_rss?(current_result)
          environment = baseline_document.fetch('environment')
          current_result['rss_kind'] == environment['rss_kind'] &&
            current_result['rss_scope'] == environment['rss_scope']
        end

        def relative_limit(baseline_value, ratio:, allowance:, absolute:)
          [baseline_value * ratio, baseline_value + allowance].max.clamp(0, absolute)
        end

        def rss_value(performance)
          value = performance['process_hwm_kb'] || performance['process_rss_kb']
          Integer(value) if value
        end

        def unavailable(diagnostic)
          { 'passed' => false, 'available' => false, 'diagnostic' => diagnostic }
        end
      end
    end
  end
end
