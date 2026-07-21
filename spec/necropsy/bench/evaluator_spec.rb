# frozen_string_literal: true

RSpec.describe Necropsy::Bench::Evaluator do
  it 'calculates precision, recall, grouped metrics, and release criteria' do
    true_positive = finding(id: 'Sample#dead', classification: :unreachable, confidence: :high)
    false_positive = finding(id: 'Sample#maybe', classification: :unused, confidence: :medium)
    report = report_with_findings([true_positive, false_positive])

    with_project(files: {
      'gold.yml' => {
        'dead_methods' => [
          { 'id' => 'Sample#dead', 'classification' => 'unreachable' },
          { 'id' => 'Sample#missing', 'classification' => 'unreachable' }
        ]
      }.to_yaml
    }) do |root|
      result = described_class.new(
        report: report,
        gold_standard_path: File.join(root, 'gold.yml'),
        min_confidence: :low,
        precision_threshold: 0.4,
        recall_threshold: 0.4
      ).call

      expect(result).to include(
        'precision' => 0.5,
        'recall' => 0.5,
        'f1' => 0.5,
        'true_positive' => ['Sample#dead'],
        'false_positive' => ['Sample#maybe'],
        'false_negative' => ['Sample#missing']
      )
      expect(result.fetch('by_classification').keys).to contain_exactly('unreachable', 'unused')
      expect(result.fetch('by_confidence').keys).to contain_exactly('high', 'medium')
      expect(result.dig('by_confidence', 'high', 'recall')).to be_nil
      expect(result.dig('by_confidence', 'high', 'false_negative')).to eq([])
      expect(result.fetch('release_criteria')).to include('passed' => true)
    end
  end
end
