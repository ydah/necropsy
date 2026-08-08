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

  it 'does not turn blocked unknown-receiver findings into RTA ablation candidates' do
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
      expect(rank_only.dig('candidate_diff', 'only_in_legacy')).to eq([])
      expect(legacy.fetch('true_positive')).to eq([])
    end
  end

  it 'reports legacy logical and physical definition identity views without collapsing duplicates' do
    first = finding(id: 'Repeated#dead', file: 'lib/repeated.rb', line: 2)
    first = first.with(node: first.node.with(definition_id: 'def:v1:first', body_digest: 'first', ordinal: 1))
    second = finding(id: 'Repeated#dead', file: 'lib/repeated.rb', line: 6)
    second = second.with(node: second.node.with(definition_id: 'def:v1:second', body_digest: 'second', ordinal: 1))
    report = report_with_findings([first, second])

    with_project(files: { 'gold.yml' => { 'dead_methods' => ['Repeated#dead'] }.to_yaml }) do |root|
      result = described_class.new(
        report: report,
        gold_standard_path: File.join(root, 'gold.yml'),
        min_confidence: :low
      ).call

      expect(result.dig('identity_views', 'legacy_logical')).to include(
        'identity_key' => 'symbol_id',
        'candidate_count' => 1,
        'candidate_ids' => ['Repeated#dead']
      )
      physical = result.dig('identity_views', 'physical_definition')
      expect(physical.fetch('candidate_count')).to eq(2)
      expect(physical.fetch('candidates').map { |candidate| candidate['definition_id'] }).to eq(
        %w[def:v1:first def:v1:second]
      )
      expect(physical.fetch('candidates').map { |candidate| candidate['physical_fingerprint'] }.uniq.length).to eq(2)
    end
  end

  it 'reports actionable precision, known-positive recall, LOC, diagnostics, rules, risks, and categories' do
    rule_evidence = evidence(metadata: { 'rule_id' => 'registry.literal', 'benchmark_category' => 'registry' })
    candidate = finding(id: 'Measured#dead', classification: :unreachable).with(
      node: node('Measured#dead', line: 3, end_line: 5),
      evidences: [rule_evidence]
    )
    blocker = Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: :message,
      scope_value: 'call',
      source: :spec,
      reason: 'receiver is unknown',
      metadata: { 'benchmark_category' => 'dispatch' }
    )
    blocked = finding(id: 'Measured#blocked', classification: :blocked, confidence: :low, blockers: [blocker])
    test_only = finding(id: 'Measured#test', classification: :test_only_reachable)
    report = report_with_findings([candidate, blocked, test_only])

    with_project(files: {
                   'gold.yml' => {
                     'dead_methods' => [{ 'id' => 'Measured#dead', 'category' => 'registry' }],
                     'known_positives' => [
                       { 'id' => 'Measured#dead', 'category' => 'registry' },
                       { 'id' => 'Measured#missing', 'category' => 'registry' }
                     ]
                   }.to_yaml
                 }) do |root|
      result = described_class.new(
        report: report,
        gold_standard_path: File.join(root, 'gold.yml'),
        precision_threshold: 0.8
      ).call

      expect(result.fetch('quality')).to include(
        'candidate_precision' => 1.0,
        'candidate_count' => 1,
        'candidate_loc' => 3,
        'known_positive_recall' => 0.5,
        'diagnostic_count' => 2,
        'blocked_count' => 1,
        'blocked_rate' => 0.3333,
        'unknown_finding_count' => 1,
        'unknown_finding_rate' => 0.3333,
        'rule_counts' => { 'registry.literal' => 1 }
      )
      expect(result.dig('quality', 'risk_counts')).to include('public_or_protected_visibility' => 3)
      expect(result.dig('by_category', 'registry')).to include(
        'candidate_precision' => 1.0,
        'candidate_count' => 1,
        'candidate_loc' => 3,
        'known_positive_recall' => 0.5,
        'rule_counts' => { 'registry.literal' => 1 }
      )
      expect(result.dig('by_category', 'dispatch')).to include(
        'candidate_count' => 0, 'blocked_count' => 1, 'blocked_rate' => 1.0,
        'unknown_count' => 1, 'unknown_rate' => 1.0
      )
      expect(result.dig('release_criteria', 'checks')).to include(
        'precision' => true, 'candidate_yield' => true
      )
    end
  end

  it 'fails the precision gate when candidate yield is zero' do
    blocked = finding(id: 'Measured#blocked', classification: :blocked, confidence: :low)
    report = report_with_findings([blocked])

    with_project(files: { 'gold.yml' => { 'dead_methods' => [] }.to_yaml }) do |root|
      result = described_class.new(
        report: report,
        gold_standard_path: File.join(root, 'gold.yml'),
        precision_threshold: 0.0
      ).call

      expect(result).to include('precision' => 0.0)
      expect(result.fetch('quality')).to include('candidate_count' => 0, 'candidate_loc' => 0)
      expect(result.dig('release_criteria', 'checks', 'candidate_yield')).to be(false)
      expect(result.dig('release_criteria', 'passed')).to be(false)
    end
  end

  it 'compares arbitrary feature on and off reports with physical candidate differences' do
    retained = finding(id: 'Measured#retained').with(
      node: node('Measured#retained', definition_id: 'def:retained', line: 2, end_line: 3)
    )
    removed = finding(id: 'Measured#removed').with(
      node: node('Measured#removed', definition_id: 'def:removed', line: 7, end_line: 10)
    )
    feature_on = report_with_findings([retained])
    feature_off = report_with_findings([retained, removed])

    with_project(files: {
                   'gold.yml' => { 'dead_methods' => %w[Measured#retained Measured#removed] }.to_yaml
                 }) do |root|
      result = described_class.new(
        report: feature_on,
        gold_standard_path: File.join(root, 'gold.yml'),
        feature_ablation: { 'receiver_flow' => { on: feature_on, off: feature_off } }
      ).call
      difference = result.dig('feature_ablation', 'receiver_flow', 'difference')

      expect(difference).to include(
        'candidate_count' => -1,
        'candidate_loc' => -4,
        'only_with_feature' => [],
        'only_without_feature' => ['def:removed']
      )
      expect(difference.dig('by_category', 'uncategorized')).to include(
        'candidate_count' => -1, 'candidate_loc' => -4
      )
      expect(result.dig('feature_ablation', 'receiver_flow', 'on', 'candidate_count')).to eq(1)
      expect(result.dig('feature_ablation', 'receiver_flow', 'off', 'candidate_count')).to eq(2)
    end
  end
end
