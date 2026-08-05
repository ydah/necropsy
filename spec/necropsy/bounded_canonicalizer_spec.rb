# frozen_string_literal: true

RSpec.describe Necropsy::BoundedCanonicalizer do
  it 'canonicalizes typed hash keys independently of insertion order' do
    forward = { a: 1, 'a' => 2 }
    reverse = { 'a' => 2, a: 1 }

    expect(described_class.dump(reverse)).to eq(described_class.dump(forward))
    expect(described_class.dump(forward)).not_to eq(described_class.dump({ 'a' => 2 }))
  end

  it 'handles invalid bytes without replacing or merging them' do
    first = described_class.dump("\xFF".b)
    second = described_class.dump("\xFE".b)

    expect(first).not_to eq(second)
    expect(first).to include('ASCII-8BIT', 'ff')
  end

  it 'normalizes equivalent valid strings across serialization encodings' do
    utf8 = 'plain'.encode(Encoding::UTF_8)
    ascii = 'plain'.encode(Encoding::US_ASCII)
    latin1 = "\xE9".dup.force_encoding(Encoding::ISO_8859_1)

    expect(described_class.dump(ascii)).to eq(described_class.dump(utf8))
    expect(described_class.dump(latin1)).to eq(described_class.dump('é'))
  end

  it 'rejects cycles, unsupported values, and configured limits with typed errors' do
    cyclic = []
    cyclic << cyclic

    expect { described_class.dump(cyclic) }.to raise_error(described_class::CycleError)
    expect { described_class.dump(Object.new) }.to raise_error(described_class::UnsupportedTypeError)
    expect do
      described_class.dump([[[1]]], max_depth: 2)
    end.to raise_error(described_class::LimitError, /depth/)
    expect do
      described_class.dump(%w[a b c], max_items: 2)
    end.to raise_error(described_class::LimitError, /item count/)
  end

  it 'canonicalizes deep payloads without recursive JSON generation' do
    nested = :leaf
    120.times { nested = [nested] }

    expect(described_class.dump(nested)).to start_with('["array"')
  end

  it 'enforces an aggregate work budget before visiting later hash entries' do
    payload = { 'first' => 'a' * 20, 'second' => 'b' * 20, 'sentinel' => Object.new }

    expect do
      described_class.dump(payload, max_total_bytes: 100)
    end.to raise_error(described_class::LimitError, /maximum size/)
  end
end
