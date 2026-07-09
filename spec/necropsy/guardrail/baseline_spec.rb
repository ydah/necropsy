# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Baseline do
  it 'loads an empty baseline when no file exists' do
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    expect(described_class.load(path).fingerprints).to eq([])
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
end
