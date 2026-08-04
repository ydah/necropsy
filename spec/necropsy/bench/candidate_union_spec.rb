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
end
