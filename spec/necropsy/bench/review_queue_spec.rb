# frozen_string_literal: true

RSpec.describe Necropsy::Bench::ReviewQueue do
  let(:reports) do
    {
      'beta' => {
        'findings' => [
          { 'id' => 'Beta#low', 'state' => 'unreachable', 'confidence' => 'low', 'candidate' => true },
          { 'id' => 'Beta#high', 'state' => 'unreachable', 'confidence' => 'high', 'candidate' => true }
        ]
      },
      'alpha' => {
        'findings' => [
          { 'id' => 'Alpha#medium', 'state' => 'unreachable', 'confidence' => 'medium', 'candidate' => true },
          { 'id' => 'Alpha#blocked', 'state' => 'blocked', 'confidence' => 'low', 'candidate' => false }
        ]
      }
    }
  end

  it 'creates a deterministic pending queue without labels or review outcomes' do
    queue = described_class.new(reports: reports, target_reviewed_high: 2, limit: 3).call

    expect(queue).to include(
      'status' => 'pending',
      'available_actionable_candidates' => 3,
      'queued_candidates' => 3,
      'reviewed_candidates' => 0,
      'reviewed_high_candidates' => 0,
      'pending_high_candidates' => 1,
      'target_shortfall' => 0,
      'legacy_high_target_shortfall' => 1,
      'claim_gate_passed' => false
    )
    expect(queue.fetch('entries').map { |entry| entry.fetch('id') }).to eq(
      ['Beta#high', 'Alpha#medium', 'Beta#low']
    )
    expect(queue.fetch('entries')).to all(include('status' => 'pending'))
    expect(queue.fetch('entries')).to all(satisfy { |entry| !entry.key?('label') && !entry.key?('outcome') })
    expect(queue.fetch('corpora')).to include(
      'alpha' => include('available_candidates' => 1),
      'beta' => include('available_candidates' => 2)
    )
    expect(queue).to eq(described_class.new(reports: reports, target_reviewed_high: 2, limit: 3).call)
  end

  it 'uses candidate states when a normalized report omitted the candidate flag' do
    queue = described_class.new(
      reports: { 'fixture' => { 'findings' => [{ 'id' => 'Seed#dead', 'state' => 'unused', 'confidence' => 'medium' }] } },
      target_reviewed_high: 1,
      limit: 1
    ).call

    expect(queue.fetch('entries').first).to include('id' => 'Seed#dead', 'review_class' => 'candidate')
  end

  it 'does not let a diagnostic actionability flag become a review candidate' do
    queue = described_class.new(
      reports: {
        'fixture' => { 'findings' => [
          { 'id' => 'Diagnostic#dead', 'state' => 'unreachable', 'confidence' => 'high', 'candidate' => true,
            'actionability' => 'diagnostic' },
          { 'id' => 'Review#dead', 'state' => 'unreachable', 'confidence' => 'low', 'candidate' => false,
            'actionability' => 'review_candidate' }
        ] }
      },
      target_reviewed_high: 1,
      limit: 2
    ).call

    expect(queue.fetch('entries').map { |entry| entry.fetch('id') }).to eq(['Review#dead'])
    expect(queue.fetch('target_shortfall')).to eq(0)
  end

  it 'rejects a non-positive target' do
    expect do
      described_class.new(reports: reports, target_reviewed_high: 0)
    end.to raise_error(Necropsy::Error, /target must be positive/)
  end

  it 'rejects malformed findings before selecting queue entries' do
    expect do
      described_class.new(reports: { 'fixture' => { 'findings' => ['not-a-finding'] } }).call
    end.to raise_error(Necropsy::Error, /findings must be mappings/)
  end

  it 'rejects findings missing queue identity fields' do
    expect do
      described_class.new(
        reports: { 'fixture' => { 'findings' => [{ 'id' => 'Fixture#dead' }] } }
      ).call
    end.to raise_error(Necropsy::Error, /findings require state/)
  end

  it 'rejects blank queue identity fields' do
    expect do
      described_class.new(
        reports: {
          'fixture' => { 'findings' => [{ 'id' => '', 'state' => 'unreachable', 'confidence' => 'low' }] }
        }
      ).call
    end.to raise_error(Necropsy::Error, /findings require id/)
  end
end
