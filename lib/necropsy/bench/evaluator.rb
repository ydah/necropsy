# frozen_string_literal: true

require 'yaml'
require_relative 'finding_facts'

module Necropsy
  module Bench
    class Evaluator
      ABLATION_ANALYZERS = {
        'name_resolution' => [Analyzers::Static::NameResolution],
        'cha' => [Analyzers::Static::CHA],
        'rta' => [Analyzers::Static::RTA],
        'name_resolution+cha' => [Analyzers::Static::NameResolution, Analyzers::Static::CHA],
        'name_resolution+rta' => [Analyzers::Static::NameResolution, Analyzers::Static::RTA],
        'all_static' => [Analyzers::Static::NameResolution, Analyzers::Static::CHA, Analyzers::Static::RTA]
      }.freeze

      def initialize(
        report:,
        gold_standard_path:,
        min_confidence: :low,
        root: nil,
        config_path: nil,
        ablation: false,
        feature_ablation: {},
        precision_threshold: 0.85,
        recall_threshold: nil
      )
        @report = report
        @gold_standard_path = gold_standard_path
        @min_confidence = min_confidence
        @root = root
        @config_path = config_path
        @ablation = ablation
        @feature_ablation = feature_ablation
        @precision_threshold = precision_threshold
        @recall_threshold = recall_threshold
      end

      def call
        result = metrics_for(report)
        result['identity_views'] = identity_views(report)
        result['quality'] = quality_metrics(report)
        result['by_category'] = category_metrics(report)
        result['by_classification'] = grouped_metrics(:classification)
        result['by_confidence'] = grouped_metrics(:confidence)
        result['ablation'] = ablation_metrics if ablation && root
        result['feature_ablation'] = feature_ablation_metrics unless feature_ablation.empty?
        result['release_criteria'] = release_criteria(result)
        result
      end

      private

      attr_reader :report, :gold_standard_path, :min_confidence, :root, :config_path, :ablation, :precision_threshold,
                  :recall_threshold, :feature_ablation

      def metrics_for(target_report, expected: gold_standard, recall_expected: expected)
        actual = actionable_findings(target_report).to_set { |finding| finding.node.id }
        true_positive = actual & expected
        false_positive = actual - expected
        false_negative = recall_expected ? recall_expected - actual : Set.new

        precision = ratio(true_positive.length, actual.length)
        recall = ratio((actual & recall_expected).length, recall_expected.length) if recall_expected
        f1 = if recall
               (precision + recall).zero? ? 0.0 : (2 * precision * recall / (precision + recall))
             end

        {
          'precision' => precision.round(4),
          'recall' => recall&.round(4),
          'f1' => f1&.round(4),
          'true_positive' => true_positive.to_a.sort,
          'false_positive' => false_positive.to_a.sort,
          'false_negative' => false_negative.to_a.sort
        }
      end

      def gold_standard(classification: nil, confidence: nil)
        entries = gold_entries
        if classification
          scoped = entries.select do |entry|
            !entry.key?('classification') || entry['classification'] == classification.to_s
          end
          return ids_for(scoped)
        end
        if confidence
          scoped = entries.select { |entry| entry['confidence'] == confidence.to_s }
          return nil if scoped.empty?

          return ids_for(scoped)
        end

        ids_for(entries)
      end

      def gold_entries
        payload = gold_payload
        entries = if payload.is_a?(Hash)
                    payload['dead_methods'] || payload['findings'] || dead_labels(payload['labels']) || []
                  else
                    payload
                  end
        normalize_entries(entries).select do |entry|
          classification = entry['classification']
          classification.nil? || FindingFacts::ACTIONABLE_CLASSIFICATIONS.include?(classification.to_sym)
        end
      end

      def known_positive_entries
        payload = gold_payload
        entries = payload['known_positives'] || payload['known_positive_methods'] if payload.is_a?(Hash)
        entries ? normalize_entries(entries) : gold_entries
      end

      def gold_payload
        @gold_payload ||= YAML.safe_load_file(gold_standard_path, aliases: true) || {}
      end

      def normalize_entries(entries)
        Array(entries).map do |entry|
          entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : { 'id' => entry }
        end
      end

      def dead_labels(entries)
        return unless entries

        Array(entries).select { |entry| entry.is_a?(Hash) && (entry['value'] || entry[:value]).to_s == 'dead' }
      end

      def ids_for(entries)
        entries.map { |entry| entry['id'] || entry['node_id'] }.compact.to_set
      end

      def grouped_metrics(attribute)
        report.reportable_findings.group_by { |finding| finding.public_send(attribute) }.transform_values do |findings|
          value = findings.first.public_send(attribute)
          grouped_report = Report.new(root: report.root, graph: report.graph, findings: findings)
          if attribute == :classification
            expected_scope = gold_standard(classification: value)
            metrics_for(grouped_report, expected: expected_scope)
          else
            expected_scope = gold_standard(confidence: value)
            if expected_scope
              metrics_for(grouped_report, expected: expected_scope)
            else
              metrics_for(grouped_report, expected: gold_standard, recall_expected: nil)
            end
          end
        end.transform_keys(&:to_s)
      end

      def ablation_metrics
        analyzer_metrics = ABLATION_ANALYZERS.transform_values do |classes|
          analyzers = classes.map(&:new)
          measurement_for(Necropsy.analyze(
                            root: root,
                            config_path: config_path,
                            analyzers: analyzers,
                            ignored_reference_paths: [gold_standard_path]
                          ))
        end
        analyzer_metrics.merge(rta_pruning_metrics)
      end

      def rta_pruning_metrics
        analyzers = ABLATION_ANALYZERS.fetch('all_static').map(&:new)
        rank_only = measurement_for(
          Runner.new(
            root: root,
            config_path: config_path,
            analyzers: analyzers,
            ignored_reference_paths: [gold_standard_path]
          ).analyze(rta_pruning: :rank_only)
        )
        legacy = measurement_for(
          Runner.new(
            root: root,
            config_path: config_path,
            analyzers: analyzers,
            ignored_reference_paths: [gold_standard_path]
          ).analyze(rta_pruning: :legacy)
        )
        rank_candidates = candidate_ids(rank_only)
        legacy_candidates = candidate_ids(legacy)
        difference = {
          'only_in_rank_only' => (rank_candidates - legacy_candidates).sort,
          'only_in_legacy' => (legacy_candidates - rank_candidates).sort
        }
        {
          'rta_rank_only' => rank_only.merge('rta_pruning' => 'rank_only', 'candidate_diff' => difference),
          'rta_legacy' => legacy.merge('rta_pruning' => 'legacy', 'candidate_diff' => difference)
        }
      end

      def candidate_ids(metrics)
        Set.new(metrics.fetch('true_positive') + metrics.fetch('false_positive'))
      end

      def ratio(numerator, denominator)
        return 0.0 if denominator.zero?

        numerator.to_f / denominator
      end

      def identity_views(target_report)
        findings = actionable_findings(target_report)
        logical = findings.map { |finding| finding.node.symbol_id }.uniq.sort
        physical = findings.sort_by do |finding|
          [finding.node.symbol_id, finding.node.file, finding.node.line, finding.node.definition_id]
        end.map do |finding|
          {
            'definition_id' => finding.node.definition_id,
            'symbol_id' => finding.node.symbol_id,
            'physical_fingerprint' => finding.physical_fingerprint,
            'logical_fingerprint' => finding.logical_fingerprint,
            'file' => finding.node.file,
            'line' => finding.node.line
          }
        end
        {
          'legacy_logical' => {
            'identity_key' => 'symbol_id',
            'candidate_count' => logical.length,
            'candidate_ids' => logical
          },
          'physical_definition' => {
            'identity_key' => 'definition_id',
            'candidate_count' => physical.length,
            'candidates' => physical
          }
        }
      end

      def release_criteria(result)
        checks = {
          'precision' => result.dig('quality', 'candidate_precision') >= precision_threshold,
          'candidate_yield' => result.dig('quality', 'candidate_count').positive?
        }
        if recall_threshold
          known_positive_recall = result.dig('quality', 'known_positive_recall')
          checks['recall'] = !known_positive_recall.nil? && known_positive_recall >= recall_threshold
        end
        {
          'precision_threshold' => precision_threshold,
          'recall_threshold' => recall_threshold,
          'passed' => checks.values.all?,
          'checks' => checks
        }
      end

      def actionable_findings(target_report)
        if target_report.respond_to?(:actionable_candidates)
          target_report.actionable_candidates(min_confidence: min_confidence)
        else
          target_report.dead_methods(min_confidence: min_confidence).select { |finding| FindingFacts.actionable?(finding) }
        end
      end

      def quality_metrics(target_report)
        candidates = actionable_findings(target_report)
        findings = target_report.reportable_findings
        blocked = findings.select { |finding| finding.classification == :blocked }
        unknown = findings.select { |finding| FindingFacts.unknown?(finding) }
        resolutions = FindingFacts.resolution_counts(target_report)
        {
          'scope' => 'report',
          'candidate_precision' => physical_precision(candidates, gold_entries),
          'candidate_count' => candidates.length,
          'candidate_loc' => candidates.sum { |finding| FindingFacts.loc(finding) },
          'known_positive_recall' => physical_recall(candidates, known_positive_entries),
          'known_positive_count' => known_positive_entries.length,
          'diagnostic_count' => findings.count { |finding| !FindingFacts.actionable?(finding) },
          'blocked_count' => blocked.length,
          'blocked_rate' => FindingFacts.ratio(blocked.length, findings.length),
          'unknown_finding_count' => unknown.length,
          'unknown_finding_rate' => FindingFacts.ratio(unknown.length, findings.length),
          'resolution_counts' => resolutions,
          'unknown_resolution_rate' => FindingFacts.ratio(resolutions.fetch('unknown'), resolutions.fetch('total')),
          'rule_counts' => FindingFacts.report_rule_counts(target_report),
          'risk_counts' => FindingFacts.report_risk_counts(target_report)
        }
      end

      def category_metrics(target_report)
        candidates = actionable_findings(target_report)
        findings = target_report.reportable_findings
        expected = gold_entries
        known = known_positive_entries
        categories = candidates.map { |finding| category_for_finding(finding) } +
                     findings.map { |finding| category_for_finding(finding) } +
                     (expected + known).map { |entry| category_for_entry(entry) }
        categories.uniq.sort.to_h do |category|
          category_candidates = candidates.select { |finding| category_for_finding(finding) == category }
          category_findings = findings.select { |finding| category_for_finding(finding) == category }
          category_expected = expected.select { |entry| category_for_entry(entry) == category }
          category_known = known.select { |entry| category_for_entry(entry) == category }
          blocked = category_findings.select { |finding| finding.classification == :blocked }
          unknown = category_findings.select { |finding| FindingFacts.unknown?(finding) }
          [category, {
            'candidate_precision' => physical_precision(category_candidates, category_expected),
            'candidate_count' => category_candidates.length,
            'candidate_loc' => category_candidates.sum { |finding| FindingFacts.loc(finding) },
            'known_positive_recall' => physical_recall(category_candidates, category_known),
            'known_positive_count' => category_known.length,
            'finding_count' => category_findings.length,
            'blocked_count' => blocked.length,
            'blocked_rate' => FindingFacts.ratio(blocked.length, category_findings.length),
            'unknown_count' => unknown.length,
            'unknown_rate' => FindingFacts.ratio(unknown.length, category_findings.length),
            'rule_counts' => FindingFacts.tally(
              category_findings.flat_map { |finding| FindingFacts.rule_hits(finding) }
            ),
            'risk_counts' => FindingFacts.tally(
              category_findings.flat_map { |finding| FindingFacts.risk_flags(finding) }
            )
          }]
        end
      end

      def category_for_finding(finding)
        entry = (gold_entries + known_positive_entries).find do |candidate|
          entry_matches_finding?(candidate, finding)
        end
        entry ? category_for_entry(entry) : FindingFacts.category(finding)
      end

      def category_for_entry(entry)
        category = entry['category']
        category.to_s.empty? ? 'uncategorized' : category.to_s
      end

      def physical_precision(candidates, expected_entries)
        return 0.0 if candidates.empty?

        matches = candidates.count do |finding|
          expected_entries.any? { |entry| entry_matches_finding?(entry, finding) }
        end
        FindingFacts.ratio(matches, candidates.length)
      end

      def physical_recall(candidates, expected_entries)
        return nil if expected_entries.empty?

        matches = expected_entries.count do |entry|
          candidates.any? { |finding| entry_matches_finding?(entry, finding) }
        end
        FindingFacts.ratio(matches, expected_entries.length)
      end

      def entry_matches_finding?(entry, finding)
        identifier = entry['definition_id'] || entry['id'] || entry['node_id']
        [finding.node.definition_id, finding.node.symbol_id, finding.node.id].compact.include?(identifier)
      end

      def feature_ablation_metrics
        feature_ablation.sort.to_h do |name, variants|
          enabled = variant_report(variants, :on)
          disabled = variant_report(variants, :off)
          enabled_metrics = quality_metrics(enabled)
          disabled_metrics = quality_metrics(disabled)
          enabled_categories = category_metrics(enabled)
          disabled_categories = category_metrics(disabled)
          [name.to_s, {
            'on' => enabled_metrics.merge('by_category' => enabled_categories),
            'off' => disabled_metrics.merge('by_category' => disabled_categories),
            'difference' => quality_difference(
              enabled, disabled, enabled_metrics, disabled_metrics, enabled_categories, disabled_categories
            )
          }]
        end
      end

      def variant_report(variants, key)
        report = variants[key] || variants[key.to_s]
        raise Error, "Feature ablation requires #{key.inspect} report" unless report

        report
      end

      def quality_difference(enabled, disabled, enabled_metrics, disabled_metrics, enabled_categories,
                             disabled_categories)
        numeric_keys = %w[
          candidate_count candidate_loc candidate_precision known_positive_recall
          blocked_count blocked_rate unknown_finding_count unknown_finding_rate
          unknown_resolution_rate
        ]
        difference = numeric_keys.to_h do |key|
          [key, metric_delta(enabled_metrics[key], disabled_metrics[key])]
        end
        enabled_ids = physical_candidate_ids(enabled)
        disabled_ids = physical_candidate_ids(disabled)
        difference.merge(
          'only_with_feature' => (enabled_ids - disabled_ids).sort,
          'only_without_feature' => (disabled_ids - enabled_ids).sort,
          'rule_counts' => count_difference(enabled_metrics['rule_counts'], disabled_metrics['rule_counts']),
          'risk_counts' => count_difference(enabled_metrics['risk_counts'], disabled_metrics['risk_counts']),
          'by_category' => category_difference(enabled_categories, disabled_categories)
        )
      end

      def category_difference(enabled, disabled)
        (enabled.keys | disabled.keys).sort.to_h do |category|
          on = enabled.fetch(category, {})
          off = disabled.fetch(category, {})
          numeric_keys = %w[
            candidate_precision candidate_count candidate_loc known_positive_recall
            blocked_count blocked_rate unknown_count unknown_rate
          ]
          difference = numeric_keys.to_h { |key| [key, metric_delta(on[key] || 0, off[key] || 0)] }
          [category, difference.merge(
            'rule_counts' => count_difference(on.fetch('rule_counts', {}), off.fetch('rule_counts', {})),
            'risk_counts' => count_difference(on.fetch('risk_counts', {}), off.fetch('risk_counts', {}))
          )]
        end
      end

      def measurement_for(target_report)
        metrics_for(target_report).merge(
          'quality' => quality_metrics(target_report),
          'by_category' => category_metrics(target_report)
        )
      end

      def physical_candidate_ids(target_report)
        actionable_findings(target_report).to_set { |finding| finding.node.definition_id }
      end

      def metric_delta(enabled, disabled)
        return nil if enabled.nil? || disabled.nil?

        (enabled - disabled).round(4)
      end

      def count_difference(enabled, disabled)
        (enabled.keys | disabled.keys).sort.to_h do |key|
          [key, enabled.fetch(key, 0) - disabled.fetch(key, 0)]
        end
      end
    end
  end
end
