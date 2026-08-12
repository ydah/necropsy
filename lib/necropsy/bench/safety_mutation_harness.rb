# frozen_string_literal: true

module Necropsy
  module Bench
    class SafetyMutationHarness
      Result = Data.define(:name, :detected, :violations)
      HEALTH_RANK = { invalid: 0, degraded: 1, complete: 2 }.freeze

      def initialize(baseline:)
        @baseline = baseline
      end

      def evaluate(mutants)
        Hash(mutants).sort.to_h do |name, report|
          violations = violations_for(report)
          [name.to_s, Result.new(name: name.to_s, detected: violations.any?, violations: violations.freeze)]
        end
      end

      def assert_all_detected!(mutants)
        results = evaluate(mutants)
        survivors = results.values.reject(&:detected).map(&:name)
        raise Error, "Safety mutations survived: #{survivors.join(', ')}" if survivors.any?

        results
      end

      private

      attr_reader :baseline

      def violations_for(mutant)
        violations = []
        added = actionable_ids(mutant) - actionable_ids(baseline)
        violations << "actionable candidates grew: #{added.sort.join(', ')}" if added.any?
        bypassed = blocked_ids(baseline) & actionable_ids(mutant)
        violations << "blocked definitions became actionable: #{bypassed.sort.join(', ')}" if bypassed.any?
        if health_rank(mutant) > health_rank(baseline) && !baseline.analysis_health.complete?
          violations << 'incomplete analysis was promoted to healthier status'
        end
        violations
      end

      def actionable_ids(report)
        report.actionable_candidates(min_confidence: :low).to_set { |finding| finding.node.graph_id }
      end

      def blocked_ids(report)
        report.findings.select { |finding| finding.classification == :blocked }.to_set do |finding|
          finding.node.graph_id
        end
      end

      def health_rank(report)
        HEALTH_RANK.fetch(report.analysis_health.status)
      end
    end
  end
end
