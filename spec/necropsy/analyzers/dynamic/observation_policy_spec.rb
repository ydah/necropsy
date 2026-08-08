# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::ObservationPolicy do
  describe '.metadata' do
    it 'keeps v1 payloads compatible' do
      expect(described_class.metadata({ 'nodes' => [] })).to include('schema_version' => 1)
    end

    it 'rejects unsupported schema versions' do
      expect { described_class.metadata('schema_version' => 3) }
        .to raise_error(Necropsy::Error, /schema version/)
    end
  end

  describe '.compatible_merge' do
    it 'rejects incompatible v2 source environments' do
      expect do
        described_class.compatible_merge(
          { 'schema_version' => 2, 'environment' => 'production' },
          { 'schema_version' => 2, 'environment' => 'staging' }
        )
      end.to raise_error(Necropsy::Error, /environment/)
    end
  end
end
