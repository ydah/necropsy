# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Baseline do
  it 'loads an empty baseline when no file exists' do
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    expect(described_class.load(path).fingerprints).to eq(Set.new)
  end

  it 'writes finding fingerprints and reloads them' do
    target = finding(id: 'Sample#dead')
    report = report_with_findings([target])
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    described_class.write(report, path: path)
    baseline = described_class.load(path)

    expect(baseline).to include(target)
    expect(YAML.load_file(path).fetch('findings').first).to include(
      'fingerprint' => target.fingerprint,
      'node_id' => 'Sample#dead',
      'classification' => 'unreachable'
    )
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
