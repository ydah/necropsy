# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::ObservationPolicy do
  it 'marks matching and mismatching source revisions explicitly' do
    matching = described_class.metadata(
      { 'schema_version' => 2, 'source' => { 'git_sha' => 'abc' } },
      expected_revision: 'abc'
    )
    mismatching = described_class.metadata(
      { 'schema_version' => 2, 'source' => { 'git_sha' => 'old' } },
      expected_revision: 'abc'
    )

    expect(matching).to include('source_revision_status' => 'match', 'source_revision' => 'abc')
    expect(mismatching).to include('source_revision_status' => 'mismatch', 'source_revision' => 'old')
  end

  it 'marks explicitly stale observations and keeps them liveness-only' do
    metadata = described_class.metadata(
      { 'schema_version' => 2, 'source' => { 'git_sha' => 'old' }, 'stale' => true },
      expected_revision: 'abc'
    )

    expect(metadata).to include(
      'source_revision_status' => 'stale',
      'source_revision_policy' => 'accepted_for_liveness_only'
    )
    expect(described_class.evidence_scope(metadata)).to include('source_revision_status' => 'stale')
  end

  it 'rejects incompatible observation revisions during merge' do
    expect do
      described_class.compatible_merge(
        { 'source_revision' => 'abc', 'source_revision_status' => 'match' },
        { 'source_revision' => 'old', 'source_revision_status' => 'mismatch' }
      )
    end.to raise_error(Necropsy::Error, /source_revision/)
  end
end
