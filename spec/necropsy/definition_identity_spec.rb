# frozen_string_literal: true

RSpec.describe Necropsy::DefinitionIdentity do
  def parse_definition(source)
    Prism.parse(source).value.statements.body.first
  end

  it 'keeps structural body digests stable across comments and line shifts' do
    compact = parse_definition(<<~RUBY)
      def call(value)
        value + 1
      end
    RUBY
    shifted = parse_definition(<<~RUBY)
      # documentation

      def call(value)
        # implementation note
        value + 1
      end
    RUBY

    expect(described_class.body_digest(shifted)).to eq(described_class.body_digest(compact))
  end

  it 'changes structural body digests when semantics change' do
    original = parse_definition("def call(value)\n  value + 1\nend\n")
    changed = parse_definition("def call(value)\n  value + 2\nend\n")

    expect(described_class.body_digest(changed)).not_to eq(described_class.body_digest(original))
  end

  it 'preserves the v1 digest and identity bytes for existing valid definitions' do
    definition = parse_definition("def call; :ok; end\n")
    digest = described_class.body_digest(definition)

    expect(digest).to eq('0a1741f14eed3c1feeaa9a1d8536e7d8f998d98400854912cacafd21f11e93f7')
    expect(
      described_class.definition_id(
        kind: :instance_method,
        symbol_id: 'Sample#call',
        relative_path: 'lib/sample.rb',
        body_digest: digest,
        ordinal: 1
      )
    ).to eq('def:v1:b968f0e4880863ab3dc3ed8800a1280a68e75468a5f26826833f761e83d72d3b')
  end

  it 'streams structures deeper than the JSON nesting default and retains semantic leaves' do
    first = parse_definition("def call; #{'[' * 100}:ok#{']' * 100}; end\n")
    second = parse_definition("def call; #{'[' * 100}:changed#{']' * 100}; end\n")

    expect { described_class.body_digest(first) }.not_to raise_error
    expect(described_class.body_digest(second)).not_to eq(described_class.body_digest(first))
  end

  it 'fingerprints malformed string bytes without merging distinct payloads' do
    first = parse_definition("def call; \"\xFF\"; end".b)
    second = parse_definition("def call; \"\xFE\"; end".b)

    expect(described_class.body_digest(second)).not_to eq(described_class.body_digest(first))
  end

  it 'raises typed errors for limits, cycles, and unsupported payloads' do
    definition = parse_definition("def call; :ok; end\n")
    cyclic = []
    cyclic << cyclic

    expect do
      described_class.body_digest(definition, max_depth: 2)
    end.to raise_error(described_class::LimitExceeded, /depth/)
    expect do
      described_class::CanonicalDigest.new.hexdigest(cyclic)
    end.to raise_error(described_class::CycleError)
    expect do
      described_class::CanonicalDigest.new.hexdigest(Object.new)
    end.to raise_error(described_class::UnsupportedTypeError)
  end

  it 'enforces the aggregate digest work budget before later hash entries' do
    payload = { 'first' => 'a' * 20, 'second' => 'b' * 20, 'sentinel' => Object.new }
    digest = described_class::CanonicalDigest.new(max_total_bytes: 100)

    expect { digest.hexdigest(payload) }.to raise_error(described_class::LimitExceeded, /maximum size/)
  end

  it 'distinguishes identical definitions by ordinal' do
    body_digest = described_class.body_digest(parse_definition("def call; :ok; end\n"))
    attributes = {
      kind: :instance_method,
      symbol_id: 'Sample#call',
      relative_path: 'lib/sample.rb',
      body_digest: body_digest
    }

    first = described_class.definition_id(**attributes, ordinal: 1)
    second = described_class.definition_id(**attributes, ordinal: 2)

    expect(first).to match(/\Adef:v1:[0-9a-f]{64}\z/)
    expect(second).not_to eq(first)
  end

  it 'distinguishes the same symbol across source paths' do
    body_digest = described_class.body_digest(parse_definition("def call; :ok; end\n"))
    attributes = {
      kind: :instance_method,
      symbol_id: 'Sample#call',
      body_digest: body_digest,
      ordinal: 1
    }

    first = described_class.definition_id(**attributes, relative_path: 'lib/first.rb')
    second = described_class.definition_id(**attributes, relative_path: 'lib/second.rb')

    expect(second).not_to eq(first)
  end

  it 'rejects non-positive ordinals' do
    expect do
      described_class.definition_id(
        kind: :instance_method, symbol_id: 'Sample#call', relative_path: 'lib/sample.rb',
        body_digest: 'digest', ordinal: 0
      )
    end.to raise_error(ArgumentError, /ordinal must be positive/)
  end
end
