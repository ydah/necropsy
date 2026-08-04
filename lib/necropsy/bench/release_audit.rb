# frozen_string_literal: true

require_relative 'release_audit/config_validator'
require_relative 'release_audit/performance_gate'

module Necropsy
  module Bench
    class ReleaseAudit
      HIGH_CONFIDENCES = %w[high certain].freeze
      FALSE_POSITIVE_LABELS = %w[alive external].freeze
      REVIEW_FIELDS = %w[outcome rationale reviewer].freeze
      REVIEW_OUTCOMES = %w[expected_safety_change false_positive true_positive].freeze

      def initialize(inputs)
        @inputs = inputs
      end

      def call
        validate_inputs!
        comparisons = compare_reports
        new_high = newly_high_candidates(comparisons)
        review = review_status(comparisons)
        performance = performance_status
        gates = build_gates(new_high, review, performance)
        {
          'schema_version' => 1,
          'release' => config.fetch('release'),
          'baseline' => config.fetch('baseline'),
          'corpora' => comparisons,
          'new_high_candidates' => new_high,
          'review' => review,
          'performance' => performance,
          'performance_provenance' => performance_provenance,
          'adversarial_suites' => adversarial_results,
          'gates' => gates,
          'status' => gates.values.all? { |gate| gate['passed'] } ? 'pass' : 'fail'
        }
      end

      private

      attr_reader :inputs

      def config = inputs.fetch(:config)
      def baseline_reports = inputs.fetch(:baseline_reports)
      def current_reports = inputs.fetch(:current_reports)
      def current_summary = inputs.fetch(:current_summary)
      def labels = inputs.fetch(:labels)
      def reviews = inputs.fetch(:reviews)
      def baseline_performance = inputs.fetch(:baseline_performance)
      def adversarial_results = inputs.fetch(:adversarial_results)
      def current_provenance = inputs.fetch(:current_provenance)

      def validate_inputs!
        ConfigValidator.new(config, strict_release: false).validate!
        expected = config.fetch('adversarial_suites').keys.sort
        actual = adversarial_results.map { |result| result.fetch('name') }.sort
        return if actual == expected

        raise Error, "Adversarial results do not match configured suites: #{actual.inspect}"
      end

      def compare_reports
        config.fetch('corpora').sort.to_h do |corpus|
          baseline = index_findings(baseline_reports.fetch(corpus))
          current = index_findings(current_reports.fetch(corpus))
          added_ids = current.keys - baseline.keys
          removed_ids = baseline.keys - current.keys
          common_ids = baseline.keys & current.keys
          state_changed_ids = common_ids.reject { |id| baseline[id]['state'] == current[id]['state'] }
          confidence_changed_ids = common_ids.reject do |id|
            baseline[id]['confidence'] == current[id]['confidence']
          end
          [corpus, {
            'baseline_metrics' => baseline_reports.fetch(corpus).fetch('metrics'),
            'current_metrics' => current_reports.fetch(corpus).fetch('metrics'),
            'added' => change_list(added_ids, nil, current),
            'removed' => change_list(removed_ids, baseline, nil),
            'state_changed' => change_list(state_changed_ids, baseline, current),
            'confidence_changed' => change_list(confidence_changed_ids, baseline, current)
          }]
        end
      end

      def index_findings(report)
        report.fetch('findings').to_h { |finding| [finding.fetch('id'), finding] }
      end

      def change_list(ids, baseline, current)
        ids.sort.map do |id|
          {
            'id' => id,
            'before' => baseline&.fetch(id),
            'after' => current&.fetch(id)
          }.compact
        end
      end

      def newly_high_candidates(comparisons)
        comparisons.flat_map do |corpus, _comparison|
          baseline = index_findings(baseline_reports.fetch(corpus))
          current = index_findings(current_reports.fetch(corpus))
          current.values.select do |finding|
            high?(finding) && !high?(baseline[finding.fetch('id')]) && finding['state'] != 'blocked'
          end.map do |finding|
            label = labels[[corpus, finding.fetch('id')]]
            finding.slice('id', 'path', 'line', 'state', 'confidence').merge(
              'corpus' => corpus,
              'label' => label
            ).compact
          end
        end.sort_by { |candidate| [candidate['corpus'], candidate['id']] }
      end

      def high?(finding)
        finding && HIGH_CONFIDENCES.include?(finding['confidence'])
      end

      def review_status(comparisons)
        required = required_reviews(comparisons)
        supplied = reviews.to_h { |review| [review_key(review), review] }
        missing = required.reject { |item| valid_review?(supplied[review_key(item)]) }
        reviewed = required.filter_map do |item|
          review = supplied[review_key(item)]
          review if valid_review?(review)
        end
        invalid = required.filter_map do |item|
          review = supplied[review_key(item)]
          review if review && !valid_review?(review)
        end
        {
          'required' => required,
          'completed' => reviewed.sort_by { |item| review_key(item) },
          'missing' => missing,
          'invalid' => invalid.sort_by { |item| review_key(item) },
          'coverage' => review_coverage(comparisons, required, reviewed),
          'confirmed_false_positives' => reviewed.select { |item| item['outcome'] == 'false_positive' }
        }
      end

      def valid_review?(review)
        review && REVIEW_FIELDS.all? { |field| !review[field].to_s.strip.empty? } &&
          REVIEW_OUTCOMES.include?(review['outcome'])
      end

      def review_coverage(comparisons, required, reviewed)
        config.fetch('review').fetch('corpora').sort.to_h do |corpus, policy|
          changes = review_records(corpus, comparisons.fetch(corpus))
          [corpus, {
            'strategy' => policy.fetch('strategy'),
            'changes' => changes.length,
            'required' => required.count { |item| item['corpus'] == corpus },
            'completed' => reviewed.count { |item| item['corpus'] == corpus },
            'zero_difference' => changes.empty?
          }]
        end
      end

      def required_reviews(comparisons)
        config.fetch('review').fetch('corpora').sort.flat_map do |corpus, policy|
          records = review_records(corpus, comparisons.fetch(corpus))
          next records if policy.fetch('strategy') == 'all'

          records.group_by { |record| review_stratum(record) }.sort.flat_map do |_stratum, items|
            items.sort_by { |item| item['id'] }.first(Integer(policy.fetch('minimum_per_stratum')))
          end
        end
      end

      def review_records(corpus, comparison)
        %w[added removed state_changed].flat_map do |type|
          comparison.fetch(type).map do |change|
            change.merge('corpus' => corpus, 'change_type' => type)
          end
        end
      end

      def review_stratum(record)
        [record['change_type'], record.dig('before', 'state'), record.dig('after', 'state')].join(':')
      end

      def review_key(record)
        [record['corpus'], record['change_type'], record['id']]
      end

      def performance_status
        PerformanceGate.new(
          config: config,
          baseline: baseline_performance,
          current_summary: current_summary,
          current_provenance: current_provenance
        ).call
      end

      def performance_provenance
        {
          'baseline' => baseline_performance.except('corpora'),
          'current' => current_provenance
        }
      end

      def build_gates(new_high, review, performance)
        invalid_labels = new_high.reject { |candidate| valid_label?(candidate['label']) }
        false_positive_labels = new_high.select do |candidate|
          FALSE_POSITIVE_LABELS.include?(candidate.dig('label', 'value'))
        end
        unresolved_labels = new_high.select { |candidate| candidate.dig('label', 'value') == 'unknown' }
        {
          'new_high_reviewed' => gate(invalid_labels.empty?, invalid_labels.length),
          'new_high_false_positives' => gate(false_positive_labels.empty?, false_positive_labels.length),
          'new_high_unresolved' => gate(unresolved_labels.empty?, unresolved_labels.length),
          'difference_review' => gate(review['missing'].empty?, review['missing'].length),
          'review_false_positives' => gate(review['confirmed_false_positives'].empty?,
                                           review['confirmed_false_positives'].length),
          'performance' => gate(performance.values.all? { |result| result['passed'] },
                                performance.count { |_corpus, result| !result['passed'] }),
          'adversarial' => gate(adversarial_results.all? { |result| result['passed'] },
                                adversarial_results.count { |result| !result['passed'] })
        }
      end

      def valid_label?(label)
        label && %w[dead alive external unknown].include?(label['value']) &&
          !label['rationale'].to_s.strip.empty? && !label['reviewer'].to_s.strip.empty?
      end

      def gate(passed, failures)
        { 'passed' => passed, 'failures' => failures }
      end
    end
  end
end
