# frozen_string_literal: true

RSpec.describe Necropsy::TypeFact do
  it 'keeps hint facts non-authoritative for target refutation' do
    fact = described_class.new(subject: 'service', types: ['Service'], source: 'rbs', trust: :hint)

    expect(fact.safe_for_resolution?).to be(false)
    expect(fact.to_h).to include('trust' => 'hint', 'complete' => false)
  end

  it 'permits authoritative facts only when the provider is complete' do
    fact = described_class.new(
      subject: 'service', types: ['Service'], source: 'sorbet', trust: :authoritative, complete: true
    )

    expect(fact.safe_for_resolution?).to be(true)
  end

  it 'exposes a no-provider profile without making type analysis mandatory' do
    expect(Necropsy::TypeProvider.facts(nil)).to eq([])
    expect(Necropsy::TypeProvider.profile.kind).to eq(:type)
  end
end
