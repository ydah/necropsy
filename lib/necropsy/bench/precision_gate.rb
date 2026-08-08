# frozen_string_literal: true

module Necropsy
  module Bench
    class PrecisionGate
      MAX_FEATURES = 100
      IMPROVEMENT_DIRECTIONS = {
        'candidate_precision' => :increase,
        'known_positive_recall' => :increase,
        'candidate_count' => :increase,
        'candidate_loc' => :increase,
        'blocked_count' => :decrease,
        'blocked_rate' => :decrease,
        'unknown_finding_count' => :decrease,
        'unknown_finding_rate' => :decrease,
        'unknown_resolution_rate' => :decrease
      }.freeze

      def initialize(policy:, candidate_union_summary:, feature_ablation:)
        @policy = policy
        @candidate_union_summary = candidate_union_summary
        @feature_ablation = feature_ablation
      end

      def call
        validate!
        quality = quality_status
        features = feature_status
        checks = {
          'precision' => quality.fetch('precision_passed'),
          'candidate_yield' => quality.fetch('yield_passed'),
          'default_features_evaluated' => features.values.all? { |feature| feature['evaluated'] },
          'default_features_improve' => features.values.all? { |feature| feature['passed'] }
        }
        {
          'schema_version' => 1,
          'enforced' => true,
          'policy' => normalized_policy,
          'quality' => quality,
          'features' => features,
          'checks' => checks,
          'passed' => checks.values.all?
        }
      end

      private

      attr_reader :policy, :candidate_union_summary, :feature_ablation

      def validate!
        raise Error, 'Precision gate policy must be a mapping' unless policy.is_a?(Hash)
        raise Error, 'Candidate-union summary must be a mapping' unless candidate_union_summary.is_a?(Hash)
        raise Error, 'Feature ablation results must be a mapping' unless feature_ablation.is_a?(Hash)
        raise Error, "Feature ablation exceeds #{MAX_FEATURES} entries" if feature_ablation.length > MAX_FEATURES

        threshold = minimum_precision
        raise Error, 'Precision gate minimum_precision must be between 0.0 and 1.0' unless threshold.between?(0.0, 1.0)

        features = default_features
        raise Error, 'Precision gate default_features must not be empty' if features.empty?
        raise Error, "Precision gate default_features exceed #{MAX_FEATURES} entries" if features.length > MAX_FEATURES
        raise Error, 'Precision gate default_features must be unique strings' unless
          features.all? { |name| name.is_a?(String) && !name.empty? } && features.uniq == features
      end

      def normalized_policy
        {
          'minimum_precision' => minimum_precision,
          'default_features' => default_features.sort
        }
      end

      def minimum_precision
        Float(policy.fetch('minimum_precision', 0.85))
      rescue ArgumentError, TypeError
        Float::NAN
      end

      def default_features
        value = policy['default_features']
        raise Error, 'Precision gate default_features must be an array' unless value.is_a?(Array)

        value
      end

      def quality_status
        metrics = candidate_union_summary.dig('tool_metrics', 'necropsy')
        metrics = {} unless metrics.is_a?(Hash)
        precision = metrics['candidate_precision']
        candidate_count = nonnegative_integer(metrics['candidate_count'])
        candidate_loc = nonnegative_integer(metrics['candidate_loc'])
        measured = metrics['precision_status'] == 'measured' && precision.is_a?(Numeric) && precision.finite?
        {
          'candidate_precision' => precision,
          'minimum_precision' => minimum_precision,
          'precision_status' => metrics['precision_status'] || 'missing',
          'candidate_count' => candidate_count,
          'candidate_loc' => candidate_loc,
          'precision_passed' => measured && precision >= minimum_precision,
          'yield_passed' => candidate_count&.positive? && candidate_loc&.positive?
        }
      end

      def feature_status
        default_features.sort.to_h do |name|
          result = feature_ablation[name]
          difference = result['difference'] if result.is_a?(Hash)
          evaluated = result.is_a?(Hash) && result['on'].is_a?(Hash) && result['off'].is_a?(Hash) &&
                      difference.is_a?(Hash)
          precision_delta = numeric_delta(difference, 'candidate_precision')
          improved_metrics = evaluated ? improved_metrics(difference) : []
          precision_preserved = evaluated && !precision_delta.nil? && precision_delta >= 0
          [name, {
            'evaluated' => evaluated,
            'precision_delta' => precision_delta,
            'precision_preserved' => precision_preserved,
            'improved_metrics' => improved_metrics,
            'passed' => precision_preserved && !improved_metrics.empty?
          }]
        end
      end

      def improved_metrics(difference)
        IMPROVEMENT_DIRECTIONS.filter_map do |metric, direction|
          delta = numeric_delta(difference, metric)
          next if delta.nil? || delta.zero?

          metric if (direction == :increase && delta.positive?) || (direction == :decrease && delta.negative?)
        end
      end

      def numeric_delta(difference, key)
        return nil unless difference.is_a?(Hash)

        value = difference[key]
        value if value.is_a?(Numeric) && value.finite?
      end

      def nonnegative_integer(value)
        value if value.is_a?(Integer) && value >= 0
      end
    end
  end
end
