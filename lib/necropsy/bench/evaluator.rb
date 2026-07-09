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
        result['by_classification'] = grouped_metrics(:classification)
        result['by_confidence'] = grouped_metrics(:confidence)
        result['ablation'] = ablation_metrics if ablation && root
        result['release_criteria'] = release_criteria(result)
        result
      end

      private

      attr_reader :report, :gold_standard_path, :min_confidence, :root, :config_path, :ablation, :precision_threshold,
                  :recall_threshold

      def metrics_for(target_report, expected: gold_standard)
        actual = target_report.dead_methods(min_confidence: min_confidence).to_set { |finding| finding.node.id }
        true_positive = actual & expected
        false_positive = actual - expected
        false_negative = expected - actual

        precision = ratio(true_positive.length, actual.length)
        recall = ratio(true_positive.length, expected.length)
        f1 = (precision + recall).zero? ? 0.0 : (2 * precision * recall / (precision + recall))

        {
          'precision' => precision.round(4),
          'recall' => recall.round(4),
          'f1' => f1.round(4),
          'true_positive' => true_positive.to_a.sort,
          'false_positive' => false_positive.to_a.sort,
          'false_negative' => false_negative.to_a.sort
        }
      end

      def gold_standard(classification: nil)
        entries = gold_entries
        if classification
          scoped = entries.select do |entry|
            !entry.key?('classification') || entry['classification'] == classification.to_s
          end
          return ids_for(scoped)
        end

        ids_for(entries)
      end

      def gold_entries
        payload = YAML.load_file(gold_standard_path) || {}
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
          expected_scope = attribute == :classification ? gold_standard(classification: findings.first.public_send(attribute)) : gold_standard
          metrics_for(Report.new(root: report.root, graph: report.graph, findings: findings), expected: expected_scope)
        end.transform_keys(&:to_s)
      end

      def ablation_metrics
        ABLATION_ANALYZERS.transform_values do |classes|
          analyzers = classes.map(&:new)
          metrics_for(Necropsy.analyze(root: root, config_path: config_path, analyzers: analyzers))
        end
      end

      def ratio(numerator, denominator)
        return 1.0 if denominator.zero?

        numerator.to_f / denominator
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
