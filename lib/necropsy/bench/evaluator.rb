# frozen_string_literal: true

require 'yaml'

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
        precision_threshold: 0.85,
        recall_threshold: nil
      )
        @report = report
        @gold_standard_path = gold_standard_path
        @min_confidence = min_confidence
        @root = root
        @config_path = config_path
        @ablation = ablation
        @precision_threshold = precision_threshold
        @recall_threshold = recall_threshold
      end

      def call
        result = metrics_for(report)
        result['identity_views'] = identity_views(report)
        result['by_classification'] = grouped_metrics(:classification)
        result['by_confidence'] = grouped_metrics(:confidence)
        result['ablation'] = ablation_metrics if ablation && root
        result['release_criteria'] = release_criteria(result)
        result
      end

      private

      attr_reader :report, :gold_standard_path, :min_confidence, :root, :config_path, :ablation, :precision_threshold,
                  :recall_threshold

      def metrics_for(target_report, expected: gold_standard, recall_expected: expected)
        actual = target_report.dead_methods(min_confidence: min_confidence).to_set { |finding| finding.node.id }
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
        payload = YAML.safe_load_file(gold_standard_path, aliases: true) || {}
        entries = payload['dead_methods'] || payload['findings'] || payload
        Array(entries).map do |entry|
          entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : { 'id' => entry }
        end
      end

      def ids_for(entries)
        entries.map { |entry| entry['id'] || entry['node_id'] }.compact.to_set
      end

      def grouped_metrics(attribute)
        report.findings.group_by { |finding| finding.public_send(attribute) }.transform_values do |findings|
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
          metrics_for(Necropsy.analyze(
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
        rank_only = metrics_for(
          Runner.new(
            root: root,
            config_path: config_path,
            analyzers: analyzers,
            ignored_reference_paths: [gold_standard_path]
          ).analyze(rta_pruning: :rank_only)
        )
        legacy = metrics_for(
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
        return 1.0 if denominator.zero?

        numerator.to_f / denominator
      end

      def identity_views(target_report)
        findings = target_report.dead_methods(min_confidence: min_confidence)
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
        checks = { 'precision' => result['precision'] >= precision_threshold }
        checks['recall'] = result['recall'] >= recall_threshold if recall_threshold
        {
          'precision_threshold' => precision_threshold,
          'recall_threshold' => recall_threshold,
          'passed' => checks.values.all?,
          'checks' => checks
        }
      end
    end
  end
end
