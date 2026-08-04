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
