# frozen_string_literal: true

module Necropsy
  module Bench
    # Final, configurable gate for a public accuracy claim. It is deliberately
    # disabled unless a release config opts in with `claim_gate`.
    class ClaimGate
      ACTIONABLE_STATES = %w[unreachable unused candidate].freeze

      def initialize(config:, reports:, summary:, adversarial_results:)
        @config = config || {}
        @reports = reports || {}
        @summary = summary || {}
        @adversarial_results = Array(adversarial_results)
      end

      def call
        policy = normalized_policy
        return { 'schema_version' => 1, 'enforced' => false, 'passed' => true } unless policy

        checks = {
          'corpus_count' => reports.length >= policy.fetch('minimum_corpora'),
          'category_coverage' => category_coverage?(policy.fetch('required_categories')),
          'high_candidates_explained' => unexplained_high_candidates.empty?,
          'adversarial_suites' => adversarial_results.all? { |result| result['passed'] == true },
          'candidate_precision' => precision_measured?,
          'candidate_yield' => candidate_yield?
        }
        checks['reviewed_high_target'] = reviewed_high_count >= policy.fetch('minimum_reviewed_high')
        {
          'schema_version' => 1,
          'enforced' => true,
          'policy' => policy,
          'checks' => checks,
          'unexplained_high_candidates' => unexplained_high_candidates,
          'reviewed_high_candidates' => reviewed_high_count,
          'passed' => checks.values.all?
        }
      end

      private

      attr_reader :config, :reports, :summary, :adversarial_results

      def normalized_policy
        raw = config['claim_gate']
        return unless raw
        raise Error, 'claim_gate must be a mapping' unless raw.is_a?(Hash)

        categories = Array(raw['required_categories'] || []).map(&:to_s).reject(&:empty?).uniq.sort
        minimum_corpora = Integer(raw.fetch('minimum_corpora', 5))
        minimum_reviewed_high = Integer(raw.fetch('minimum_reviewed_high', 0))
        raise Error, 'claim_gate minimums must be non-negative' if minimum_corpora.negative? || minimum_reviewed_high.negative?

        {
          'minimum_corpora' => minimum_corpora,
          'required_categories' => categories,
          'minimum_reviewed_high' => minimum_reviewed_high
        }
      rescue ArgumentError, TypeError
        raise Error, 'claim_gate minimums must be integers'
      end

      def category_coverage?(required)
        return true if required.empty?

        categories = reports.values.flat_map do |report|
          Array(report['findings']).map { |finding| finding['category'].to_s }
        end.uniq
        required.all? { |category| categories.include?(category) }
      end

      def unexplained_high_candidates
        reports.sort.flat_map do |corpus, report|
          Array(report['findings']).filter_map do |finding|
            next unless high_candidate?(finding)
            next if Array(finding['reasons']).any? || Array(finding['rule_hits']).any? || Array(finding['blocker_kinds']).any?

            {
              'corpus' => corpus,
              'id' => finding['id'],
              'definition_id' => finding['definition_id'],
              'path' => finding['path'],
              'line' => finding['line']
            }.compact
          end
        end.sort_by { |candidate| [candidate['corpus'], candidate['id'], candidate['definition_id'].to_s] }
      end

      def high_candidate?(finding)
        %w[high certain].include?(finding['confidence'].to_s) &&
          (finding['candidate'] == true || ACTIONABLE_STATES.include?(finding['state'].to_s))
      end

      def reviewed_high_count
        summary.dig('candidate_union', 'tool_metrics', 'necropsy', 'reviewed_high_candidate_count').to_i
      end

      def necropsy_metrics
        summary.dig('candidate_union', 'tool_metrics', 'necropsy') || {}
      end

      def precision_measured?
        necropsy_metrics['precision_status'] == 'measured' && necropsy_metrics['candidate_precision'].is_a?(Numeric)
      end

      def candidate_yield?
        necropsy_metrics['candidate_count'].to_i.positive? && necropsy_metrics['candidate_loc'].to_i.positive?
      end
    end
  end
end
