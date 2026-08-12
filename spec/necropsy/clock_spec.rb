# frozen_string_literal: true

RSpec.describe Necropsy::Clock do
  it 'prefers an explicit date over SOURCE_DATE_EPOCH' do
    environment = { 'SOURCE_DATE_EPOCH' => Time.utc(2001, 2, 3).to_i.to_s }
    clock = described_class.new(as_of: '2000-01-02', environment: environment)

    expect(clock.date).to eq(Date.new(2000, 1, 2))
    expect(clock.time).to eq(Time.utc(2000, 1, 2))
  end

  it 'uses SOURCE_DATE_EPOCH when no explicit date is provided' do
    epoch = Time.utc(2001, 2, 3, 4, 5, 6)

    expect(described_class.new(environment: { 'SOURCE_DATE_EPOCH' => epoch.to_i.to_s }).time).to eq(epoch)
  end

  it 'rejects malformed reproducibility inputs' do
    expect { described_class.new(as_of: 'not-a-date') }.to raise_error(Necropsy::Error, /valid date/)
    expect do
      described_class.new(environment: { 'SOURCE_DATE_EPOCH' => 'tomorrow' })
    end.to raise_error(Necropsy::Error, /valid date/)
  end
end
