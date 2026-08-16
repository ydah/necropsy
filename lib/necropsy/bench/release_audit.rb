# frozen_string_literal: true

require_relative 'release_audit/config_validator'
require_relative 'release_audit/performance_gate'
require_relative 'precision_gate'
require_relative 'claim_gate'

module Necropsy
  module Bench
    class ReleaseAudit
      HIGH_CONFIDENCES = %w[high certain].freeze
      FALSE_POSITIVE_LABELS = %w[alive external].freeze
      REVIEW_FIELDS = %w[outcome rationale reviewer].freeze
      REVIEW_OUTCOMES = %w[expected_safety_change false_positive true_positive].freeze
      MAX_ENTRIES = 100_000
      MAX_STRING_BYTES = 4_096

      def initialize(inputs)
        @inputs = inputs
      end

      def call
        validate_inputs!
        comparisons = compare_reports
        new_high = newly_high_candidates(comparisons)
        review = review_status(comparisons)
        performance = performance_status
        precision = precision_gate_status
        claim = claim_gate_status
        gates = build_gates(new_high, review, performance, precision, claim)
        {
          'schema_version' => 1,
          'release' => config.fetch('release'),
          'baseline' => config.fetch('baseline'),
          'corpora' => comparisons,
          'new_high_candidates' => new_high,
          'review' => review,
          'performance' => performance,
          'precision_gate' => precision,
          'claim_gate' => claim,
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
        validate_mapping!(baseline_reports, 'baseline reports')
        validate_mapping!(current_reports, 'current reports')
        config.fetch('corpora').each do |corpus|
          validate_report!(baseline_reports.fetch(corpus), "baseline report #{corpus}")
          validate_report!(current_reports.fetch(corpus), "current report #{corpus}")
        end
        validate_mapping!(current_summary, 'current summary')
        validate_mapping!(labels, 'labels')
        validate_array!(reviews, 'reviews')
        reviews.each { |review| validate_mapping!(review, 'review') }
        validate_array!(adversarial_results, 'adversarial results')
        adversarial_results.each { |result| validate_mapping!(result, 'adversarial result') }
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
          actionability_changed_ids = common_ids.reject do |id|
            baseline[id]['actionability'] == current[id]['actionability']
          end
          [corpus, {
            'baseline_metrics' => baseline_reports.fetch(corpus).fetch('metrics'),
            'current_metrics' => current_reports.fetch(corpus).fetch('metrics'),
            'added' => change_list(added_ids, nil, current),
            'removed' => change_list(removed_ids, baseline, nil),
            'state_changed' => change_list(state_changed_ids, baseline, current),
            'confidence_changed' => change_list(confidence_changed_ids, baseline, current),
            'actionability_changed' => change_list(actionability_changed_ids, baseline, current)
          }]
        end
      end

      def index_findings(report)
        report.fetch('findings').each_with_object({}) do |finding, index|
          identity = finding_identity(finding)
          raise Error, "Duplicate release-audit finding identity #{identity}" if index.key?(identity)

          index[identity] = finding
        end
      end

      def change_list(ids, baseline, current)
        ids.sort.map do |identity|
          finding = current&.fetch(identity) || baseline&.fetch(identity)
          {
            'id' => finding.fetch('id'),
            'definition_id' => finding['definition_id'],
            'identity' => identity,
            'before' => baseline&.fetch(identity),
            'after' => current&.fetch(identity)
          }.compact
        end
      end

      def newly_high_candidates(comparisons)
        comparisons.flat_map do |corpus, _comparison|
          baseline = index_findings(baseline_reports.fetch(corpus))
          current = index_findings(current_reports.fetch(corpus))
          current.filter_map do |identity, finding|
            next unless high_actionable?(finding) && !high_actionable?(baseline[identity])

            label, identity_match = label_for(corpus, finding)
            finding.slice('id', 'definition_id', 'path', 'line', 'state', 'confidence', 'actionability').merge(
              'corpus' => corpus,
              'identity' => identity,
              'label' => label,
              'label_identity_match' => identity_match
            ).compact
          end
        end.sort_by { |candidate| [candidate['corpus'], candidate['id'], candidate['definition_id'].to_s] }
      end

      def label_for(corpus, finding)
        definition_id = finding['definition_id']
        physical = labels[[corpus, definition_id]] if definition_id
        return [physical, 'physical'] if physical

        legacy = labels[[corpus, finding.fetch('id')]]
        [legacy, legacy ? 'legacy_logical_fallback' : nil]
      end

      def high?(finding)
        finding && HIGH_CONFIDENCES.include?(finding['confidence'])
      end

      def high_actionable?(finding)
        high?(finding) && finding.fetch('candidate') { %w[unreachable unused candidate].include?(finding['state']) }
      end

      def review_status(comparisons)
        required = required_reviews(comparisons)
        supplied = review_indexes
        missing = required.reject { |item| valid_review?(review_for(item, supplied)) }
        reviewed = required.filter_map do |item|
          supplied_review = review_for(item, supplied)
          item.merge(supplied_review) if valid_review?(supplied_review)
        end
        invalid = required.filter_map do |item|
          supplied_review = review_for(item, supplied)
          item.merge(supplied_review) if supplied_review && !valid_review?(supplied_review)
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

      def review_indexes
        reviews.each_with_object({ physical: {}, legacy: {} }) do |review, indexes|
          base = [review['corpus'], review['change_type']]
          identity = review['definition_id']
          target = identity ? indexes[:physical] : indexes[:legacy]
          key = base + [identity || review['id']]
          raise Error, "Duplicate release-audit review identity #{key.join(':')}" if target.key?(key)

          target[key] = review
        end
      end

      def review_for(item, indexes)
        base = [item['corpus'], item['change_type']]
        definition_id = review_definition_id(item)
        physical = indexes[:physical][base + [definition_id]] if definition_id
        physical || indexes[:legacy][base + [item['id']]]
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
            items.sort_by { |item| [item['id'], review_definition_id(item).to_s] }
                 .first(Integer(policy.fetch('minimum_per_stratum')))
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
        [record['corpus'], record['change_type'], review_definition_id(record) || record['id']]
      end

      def review_definition_id(record)
        record['definition_id'] || record.dig('after', 'definition_id') || record.dig('before', 'definition_id')
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

      def precision_gate_status
        policy = config['precision_gate']
        unless policy
          return {
            'schema_version' => 1,
            'enforced' => false,
            'compatibility' => 'releases before 0.4 retain the safety-only release policy',
            'passed' => true
          }
        end

        PrecisionGate.new(
          policy: policy,
          candidate_union_summary: current_summary['candidate_union'],
          feature_ablation: current_summary['feature_ablation']
        ).call
      end

      def claim_gate_status
        ClaimGate.new(
          config: config,
          reports: current_reports,
          summary: current_summary,
          adversarial_results: adversarial_results
        ).call
      end

      def build_gates(new_high, review, performance, precision, claim)
        invalid_labels = new_high.reject { |candidate| valid_label?(candidate['label']) }
        false_positive_labels = new_high.select do |candidate|
          FALSE_POSITIVE_LABELS.include?(candidate.dig('label', 'value'))
        end
        unresolved_labels = new_high.select { |candidate| candidate.dig('label', 'value') == 'unknown' }
        gates = {
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
        gates['precision_quality'] = gate(precision['passed'], precision['passed'] ? 0 : 1) if precision['enforced']
        gates['public_claim'] = gate(claim['passed'], claim['passed'] ? 0 : 1) if claim['enforced']
        gates
      end

      def valid_label?(label)
        label && %w[dead alive external unknown].include?(label['value']) &&
          !label['rationale'].to_s.strip.empty? && !label['reviewer'].to_s.strip.empty?
      end

      def finding_identity(finding)
        finding['definition_id'] || finding.fetch('id')
      end

      def validate_report!(report, label)
        validate_mapping!(report, label)
        validate_mapping!(report['metrics'], "#{label} metrics")
        validate_array!(report['findings'], "#{label} findings")
        report['findings'].each do |finding|
          validate_mapping!(finding, "#{label} finding")
          validate_identifier!(finding['id'], "#{label} finding id")
          validate_identifier!(finding['definition_id'], "#{label} finding definition_id") if
            finding.key?('definition_id')
          validate_actionability!(finding['actionability'], "#{label} finding actionability") if
            finding.key?('actionability')
        end
      end

      def validate_mapping!(value, label)
        raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)
        raise Error, "#{label} exceeds #{MAX_ENTRIES} entries" if value.length > MAX_ENTRIES
      end

      def validate_array!(value, label)
        raise Error, "#{label} must be an array" unless value.is_a?(Array)
        raise Error, "#{label} exceeds #{MAX_ENTRIES} entries" if value.length > MAX_ENTRIES
      end

      def validate_identifier!(value, label)
        raise Error, "#{label} must be a non-empty string" unless value.is_a?(String) && !value.empty?
        raise Error, "#{label} exceeds #{MAX_STRING_BYTES} bytes" if value.bytesize > MAX_STRING_BYTES
      end

      def validate_actionability!(value, label)
        raise Error, "#{label} must be a known actionability state" unless ACTIONABILITY_LEVELS.key?(value.to_s)
      end

      def gate(passed, failures)
        { 'passed' => passed, 'failures' => failures }
      end
    end
  end
end
