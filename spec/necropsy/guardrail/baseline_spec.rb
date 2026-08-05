# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Baseline do
  def physical_finding(symbol_id:, definition_id:, body_digest:, file: 'lib/sample.rb', line: 1)
    method = node(
      symbol_id,
      symbol_id: symbol_id,
      definition_id: definition_id,
      body_digest: body_digest,
      ordinal: 1,
      file: file,
      line: line
    )
    Necropsy::Finding.new(
      node: method,
      classification: :unreachable,
      confidence: :high,
      score: 0.8,
      score_components: [],
      reasons: [],
      evidences: []
    )
  end

  it 'loads an empty baseline when no file exists' do
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    expect(described_class.load(path).fingerprints).to eq(Set.new)
  end

  it 'writes schema v2 physical fingerprints and reloads them' do
    target = physical_finding(symbol_id: 'Sample#dead', definition_id: 'def:v1:dead', body_digest: 'body-dead')
    report = report_with_findings([target])
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    described_class.write(report, path: path)
    baseline = described_class.load(path)

    expect(baseline).to include(target)
    payload = YAML.load_file(path)
    expect(payload).to include('schema_version' => 2, 'identity' => 'physical_definition')
    expect(payload.fetch('findings').first).to include(
      'fingerprint' => target.physical_fingerprint,
      'logical_fingerprint' => target.logical_fingerprint,
      'node_id' => 'Sample#dead',
      'definition_id' => 'def:v1:dead',
      'body_digest' => 'body-dead',
      'classification' => 'unreachable'
    )
  end

  it 'reads v1 logical fingerprints without rewriting them' do
    target = physical_finding(symbol_id: 'Sample#dead', definition_id: 'def:v1:new', body_digest: 'new-body')
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, {
      'version' => 1,
      'findings' => [{ 'fingerprint' => target.logical_fingerprint, 'classification' => 'unreachable' }]
    }.to_yaml)

    baseline = described_class.load(path)
    comparison = baseline.compare([target])

    expect(baseline.schema_version).to eq(1)
    expect(baseline).to include(target)
    expect(comparison.matched_findings).to eq([target])
    expect(comparison).not_to be_review_required
  end

  it 'migrates in exact, body digest, then symbol and path hint order' do
    exact = physical_finding(symbol_id: 'Sample#exact', definition_id: 'def:v1:exact', body_digest: 'same-body')
    moved = physical_finding(symbol_id: 'Renamed#call', definition_id: 'def:v1:moved', body_digest: 'moved-body')
    hinted = physical_finding(symbol_id: 'Sample#hinted', definition_id: 'def:v1:hinted-new', body_digest: 'new-body')
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, {
      'schema_version' => 2,
      'findings' => [
        { 'definition_id' => exact.node.definition_id, 'body_digest' => 'same-body',
          'symbol_id' => exact.node.symbol_id, 'file' => exact.node.file, 'classification' => 'unreachable' },
        { 'definition_id' => 'def:v1:before-move', 'body_digest' => moved.node.body_digest,
          'symbol_id' => 'BeforeMove#call', 'file' => 'lib/before_move.rb', 'classification' => 'unreachable' },
        { 'definition_id' => 'def:v1:hinted-old', 'body_digest' => 'old-body',
          'symbol_id' => hinted.node.symbol_id, 'file' => hinted.node.file, 'classification' => 'unreachable' }
      ]
    }.to_yaml)

    comparison = described_class.load(path).compare([exact, moved, hinted])

    expect(comparison.matched_findings).to contain_exactly(exact, moved, hinted)
    expect(comparison.new_findings).to be_empty
    expect(comparison).not_to be_review_required
  end

  it 'requires review when a v1 logical fingerprint maps to multiple physical definitions' do
    first = physical_finding(symbol_id: 'Sample#dead', definition_id: 'def:v1:first', body_digest: 'first')
    second = physical_finding(
      symbol_id: 'Sample#dead', definition_id: 'def:v1:second', body_digest: 'second', line: 8
    )
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, {
      'version' => 1,
      'findings' => [{ 'fingerprint' => first.logical_fingerprint, 'classification' => 'unreachable' }]
    }.to_yaml)

    comparison = described_class.load(path).compare([first, second])

    expect(comparison).to be_review_required
    expect(comparison.new_findings).to contain_exactly(first, second)
    expect(comparison.review_report).to include(
      'schema_version' => 1,
      'baseline_schema_version' => 1,
      'review_required' => true
    )
    expect(comparison.review_report.dig('ambiguities', 0)).to include(
      'strategy' => 'logical_fingerprint',
      'reason' => 'multiple_current_definitions'
    )
    expect(comparison.review_report.dig('ambiguities', 0, 'candidates').map { |entry| entry['definition_id'] }).to eq(
      %w[def:v1:first def:v1:second]
    )
  end

  it 'matches duplicate logical methods independently through exact v2 physical identities' do
    first = physical_finding(symbol_id: 'Sample#dead', definition_id: 'def:v1:first', body_digest: 'same-body')
    second = physical_finding(
      symbol_id: 'Sample#dead', definition_id: 'def:v1:second', body_digest: 'same-body', line: 8
    )
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    described_class.write(report_with_findings([first, second]), path: path)
    comparison = described_class.load(path).compare([first, second])

    expect(comparison.matched_findings).to contain_exactly(first, second)
    expect(comparison).not_to be_review_required
  end

  it 'requires review when a body digest migration is not unique' do
    first = physical_finding(symbol_id: 'First#dead', definition_id: 'def:v1:first', body_digest: 'shared-body')
    second = physical_finding(
      symbol_id: 'Second#dead', definition_id: 'def:v1:second', body_digest: 'shared-body', line: 8
    )
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, {
      'schema_version' => 2,
      'findings' => [{
        'definition_id' => 'def:v1:old',
        'body_digest' => 'shared-body',
        'classification' => 'unreachable'
      }]
    }.to_yaml)

    comparison = described_class.load(path).compare([first, second])

    expect(comparison).to be_review_required
    expect(comparison.ambiguities.first).to include(
      'strategy' => 'body_digest', 'reason' => 'multiple_current_definitions'
    )
  end

  it 'rejects unsupported schema versions instead of guessing' do
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, { 'schema_version' => 3, 'findings' => [] }.to_yaml)

    expect { described_class.load(path) }.to raise_error(Necropsy::Error, /Unsupported baseline schema version/)
  end

  it 'rejects malformed, fractional, false, and conflicting schema declarations' do
    malformed_payloads = [
      [],
      'baseline',
      false,
      { 'schema_version' => false, 'findings' => [] },
      { 'schema_version' => 2.5, 'findings' => [] },
      { 'schema_version' => 2, 'version' => 1, 'findings' => [] },
      { 'schema_version' => 2, 'findings' => 'not-an-array' },
      { 'schema_version' => 2, 'findings' => ['not-a-mapping'] }
    ]

    malformed_payloads.each do |payload|
      path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
      File.write(path, payload.to_yaml)

      expect { described_class.load(path) }.to raise_error(Necropsy::Error)
    end
  end

  it 'rejects malformed fields and contradictory identity hints' do
    logical = Digest::SHA256.hexdigest('unreachable:Sample#dead')
    malformed_entries = [
      { 'confidence' => 1 },
      { 'symbol_id' => 'Sample#dead', 'file' => 1 },
      { 'line' => 0 },
      {
        'fingerprint' => logical,
        'classification' => 'unused',
        'node_id' => 'Sample#dead',
        'file' => 'lib/sample.rb'
      }
    ]

    malformed_entries.each do |entry|
      path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
      File.write(path, { 'version' => 1, 'findings' => [entry] }.to_yaml)

      expect { described_class.load(path) }.to raise_error(Necropsy::Error)
    end

    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    File.write(path, {
      'schema_version' => 2,
      'findings' => [{
        'fingerprint' => Digest::SHA256.hexdigest('unreachable:def:v1:other'),
        'classification' => 'unreachable',
        'definition_id' => 'def:v1:target'
      }]
    }.to_yaml)
    expect { described_class.load(path) }.to raise_error(Necropsy::Error, /contradicts/)
  end

  it 'requires every v2 entry to encode its classification and identity' do
    malformed_entries = [
      {},
      { 'definition_id' => 'def:v1:target' },
      { 'classification' => 'unreachable' }
    ]

    malformed_entries.each do |entry|
      path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
      File.write(path, { 'schema_version' => 2, 'findings' => [entry] }.to_yaml)

      expect { described_class.load(path) }.to raise_error(Necropsy::Error)
    end
  end

  it 'counts only findings at or above the ratchet confidence threshold' do
    low = finding(id: 'Sample#low', confidence: :low)
    high = finding(id: 'Sample#high', confidence: :high)
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')
    described_class.write(report_with_findings([low, high]), path: path)

    baseline = described_class.load(path)

    expect(baseline.count_at_least(:high)).to eq(1)
    expect(baseline.count_at_least(:low)).to eq(2)
  end

  it 'writes only findings visible in report scope' do
    included = finding(id: 'Included#dead', file: 'lib/included.rb')
    excluded = finding(id: 'Excluded#dead', file: 'app/excluded.rb')
    graph = graph_with(nodes: [included.node, excluded.node])
    report = Necropsy::Report.new(
      root: '/repo', graph: graph, findings: [included, excluded], report_include_paths: ['lib/**']
    )
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    described_class.write(report, path: path)

    expect(YAML.load_file(path).fetch('findings').map { |entry| entry.fetch('node_id') }).to eq(
      ['Included#dead']
    )
  end
end
