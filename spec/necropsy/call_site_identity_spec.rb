# frozen_string_literal: true

RSpec.describe Necropsy::CallSiteIdentity do
  let(:source_attributes) do
    {
      caller_definition_id: 'def:v1:caller',
      relative_path: 'lib/sample.rb',
      role: :call,
      message: 'render',
      structural_digest: 'structural-digest',
      ordinal: 1
    }
  end

  it 'builds deterministic versioned source identities from canonical payloads' do
    first = described_class.source_id(**source_attributes)
    second = described_class.source_id(**source_attributes)

    expect(first).to eq(second)
    expect(first).to match(/\Acall:v1:[0-9a-f]{64}\z/)
    expect(described_class.source_id(**source_attributes, ordinal: 2)).not_to eq(first)
    expect(described_class.source_id(**source_attributes, role: :initialize)).not_to eq(first)
    expect(described_class.source_id(**source_attributes, caller_definition_id: 'def:v1:other')).not_to eq(first)
  end

  it 'derives identities from the parent site, physical caller, derivation, and message' do
    attributes = {
      parent_call_site_id: 'call:v1:parent',
      derivation: :module_function,
      caller_definition_id: 'def:v1:module-copy',
      message: 'render'
    }
    identifier = described_class.derived_id(**attributes)

    expect(identifier).to match(/\Acall:v1:[0-9a-f]{64}\z/)
    expect(described_class.derived_id(**attributes)).to eq(identifier)
    expect(described_class.derived_id(**attributes, message: 'call')).not_to eq(identifier)
    expect(described_class.derived_id(**attributes, derivation: :rta_implicit)).not_to eq(identifier)
    expect(described_class.derived_id(**attributes, discriminator: 'argument:1')).not_to eq(identifier)
  end

  it 'canonicalizes legacy metadata independently of hash insertion order' do
    attributes = {
      caller_definition_id: 'Legacy#run', message: 'render', receiver_kind: :unknown,
      receiver_name: nil, file: 'lib/legacy.rb', line: 4, test: false, dynamic: false
    }

    first = described_class.legacy_id(**attributes, metadata: { 'b' => 2, 'a' => { z: 3, y: 1 } })
    second = described_class.legacy_id(**attributes, metadata: { 'a' => { y: 1, z: 3 }, 'b' => 2 })
    mixed_first = described_class.legacy_id(**attributes, metadata: { a: 1, 'a' => 2 })
    mixed_second = described_class.legacy_id(**attributes, metadata: { 'a' => 2, a: 1 })

    expect(second).to eq(first)
    expect(mixed_second).to eq(mixed_first)
  end

  it 'rejects invalid roles, derivations, and ordinals' do
    expect { described_class.source_id(**source_attributes, role: :other) }
      .to raise_error(ArgumentError, /invalid call site role/)
    expect { described_class.source_id(**source_attributes, ordinal: 0) }
      .to raise_error(ArgumentError, /ordinal must be positive/)
    expect do
      described_class.derived_id(
        parent_call_site_id: 'call:v1:parent', derivation: :other,
        caller_definition_id: 'def:v1:caller', message: 'render'
      )
    end.to raise_error(ArgumentError, /invalid call site derivation/)
  end

  it 'rejects cyclic legacy metadata with a bounded canonicalization error' do
    cyclic = {}
    cyclic['self'] = cyclic

    expect do
      described_class.legacy_id(
        caller_definition_id: 'Legacy#run', message: 'render', receiver_kind: :unknown,
        receiver_name: nil, file: 'lib/legacy.rb', line: 4, test: false, dynamic: false,
        metadata: cyclic
      )
    end.to raise_error(Necropsy::BoundedCanonicalizer::CycleError)
  end
end
