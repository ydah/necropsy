# frozen_string_literal: true

require 'necropsy/bench/candidate_union'

RSpec.describe Necropsy::Bench::CandidateUnion do
  it 'loads at least thirty reviewed labels and preserves every comparison tool result' do
    repository_root = File.expand_path('../../..', __dir__)
    manifest = YAML.safe_load_file(File.join(repository_root, 'bench/corpora/v1/manifest.yml'))

    result = described_class.new(
      manifest: manifest,
      repository_root: repository_root,
      reports: {},
      diagnostics: []
    ).call

    expect(result.dig('summary', 'reviewed')).to be >= 30
    expect(result.fetch('candidates')).to all(
      satisfy { |candidate| candidate.fetch('tool_results').keys == %w[debride necropsy spoom type_aware] }
    )
    expect(result.fetch('candidates').map { |candidate| candidate.dig('label', 'value') }.uniq).to contain_exactly(
      'dead', 'alive', 'external', 'unknown'
    )
  end

  it 'rejects labels that do not exist in any tool candidate set' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [{ 'corpus' => 'fixture', 'id' => 'Typo#missing', 'value' => 'dead',
                                    'rationale' => 'reviewed' }]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 1,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }

      expect do
        described_class.new(manifest: manifest, repository_root: root, reports: {}, diagnostics: []).call
      end.to raise_error(Necropsy::Error, /does not match a tool candidate/)
    end
  end
end
