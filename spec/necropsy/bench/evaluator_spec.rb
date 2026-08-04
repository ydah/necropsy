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

  it 'labels rank-only and legacy RTA ablations and reports their candidate difference' do
    source = <<~RUBY
      class Base
        def render; end
      end
      class Live < Base
        def render; end
      end
      class Dead < Base
        def render; end
      end
      class Caller
        def run(receiver) = receiver.render
      end
      Live.new
    RUBY
    files = {
      'app/sample.rb' => source,
      'gold.yml' => { 'dead_methods' => ['Dead#render'] }.to_yaml
    }
    config = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }

    with_project(files: files, config: config) do |root|
      report = Necropsy.analyze(root: root)
      result = described_class.new(
        report: report,
        gold_standard_path: File.join(root, 'gold.yml'),
        root: root,
        ablation: true
      ).call
      rank_only = result.dig('ablation', 'rta_rank_only')
      legacy = result.dig('ablation', 'rta_legacy')

      expect(rank_only).to include('rta_pruning' => 'rank_only')
      expect(legacy).to include('rta_pruning' => 'legacy')
      expect(rank_only.dig('candidate_diff', 'only_in_legacy')).to contain_exactly('Base#render', 'Dead#render')
      expect(legacy.fetch('true_positive')).to eq(['Dead#render'])
    end
  end
end
