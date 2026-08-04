# frozen_string_literal: true

RSpec.describe Necropsy::DefinitionIndex do
  def physical_definition(definition_id, file:, line:)
    node(
      'Sample#run',
      symbol_id: 'Sample#run',
      definition_id: definition_id,
      body_digest: 'body-digest', ordinal: line, file: file, line: line
    )
  end

  it 'supports exact physical and unique logical lookup' do
    definition = physical_definition('def:v1:one', file: 'lib/sample.rb', line: 1)
    index = described_class.new([definition])

    expect(index.exact(definition.definition_id)).to eq(definition)
    expect(index.lookup(definition.definition_id)).to have_attributes(status: :exact, node: definition)
    expect(index.lookup(definition.symbol_id)).to have_attributes(status: :unique, node: definition)
    expect(index[definition.symbol_id]).to eq(definition)
    expect(index.lookup('Missing#run')).to be_missing
  end

  it 'returns every physical definition without silently resolving ambiguity' do
    second = physical_definition('def:v1:second', file: 'lib/second.rb', line: 2)
    first = physical_definition('def:v1:first', file: 'lib/first.rb', line: 1)
    index = described_class.new([second, first])

    lookup = index.lookup('Sample#run')

    expect(lookup).to be_ambiguous
    expect(lookup.definitions).to eq([first, second])
    expect(index.definitions_for('Sample#run')).to eq([first, second])
    expect { index['Sample#run'] }.to raise_error(
      described_class::AmbiguousDefinitionError,
      /matches 2 physical definitions/
    )
  end

  it 'enumerates definitions deterministically regardless of insertion order' do
    first = physical_definition('def:v1:first', file: 'lib/first.rb', line: 1)
    second = physical_definition('def:v1:second', file: 'lib/second.rb', line: 2)
    forward = described_class.new([first, second])
    reverse = described_class.new([second, first])

    expect(reverse.values).to eq(forward.values)
    expect(reverse.keys).to eq(forward.keys)
    expect(reverse.each.to_a).to eq(forward.each.to_a)
  end

  it 'keeps legacy nodes addressable by their logical id' do
    legacy = node('Sample#run')
    index = described_class.new([legacy])

    expect(index['Sample#run']).to eq(legacy)
    expect(index.fetch('Missing#run', :fallback)).to eq(:fallback)
    expect(index.fetch('Missing#run') { |identifier| identifier }).to eq('Missing#run')
  end
end
