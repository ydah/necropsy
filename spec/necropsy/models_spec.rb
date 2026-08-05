# frozen_string_literal: true

RSpec.describe 'Necropsy model objects' do
  describe Necropsy::Node do
    it 'serializes method metadata and stable fingerprints' do
      model = node('Sample#render', line: 10, end_line: 12, defined_via: :define_method)

      expect(model).to be_method
      expect(model.fingerprint(:unreachable)).to eq(model.fingerprint(:unreachable))
      expect(model.fingerprint(:unreachable)).not_to eq(model.fingerprint(:unused))
      expect(model.to_h).to include(
        'id' => 'Sample#render',
        'symbol_id' => 'Sample#render',
        'definition_id' => 'Sample#render',
        'body_digest' => nil,
        'ordinal' => 0,
        'kind' => 'instance_method',
        'line' => 10,
        'end_line' => 12,
        'defined_via' => 'define_method'
      )
    end

    it 'keeps legacy construction and logical fingerprints compatible' do
      legacy = described_class.new(
        id: 'Sample#render', kind: :instance_method, file: 'sample.rb', line: 1, end_line: 2,
        defined_via: :def, owner: 'Sample', name: 'render', test: false, visibility: :public
      )
      physical = legacy.with(
        definition_id: 'def:v1:physical', body_digest: 'body-digest', ordinal: 2
      )

      expect(legacy).to have_attributes(
        symbol_id: 'Sample#render', definition_id: 'Sample#render', graph_id: 'Sample#render',
        body_digest: nil, ordinal: 0
      )
      expect(physical.graph_id).to eq('def:v1:physical')
      expect(physical.fingerprint(:unreachable)).to eq(legacy.fingerprint(:unreachable))
    end

    it 'keeps the legacy positional constructor compatible' do
      values = [
        'Sample#render', :instance_method, 'sample.rb', 1, 2,
        :def, 'Sample', 'render', false, :private
      ]
      via_new = described_class.new(*values)
      via_brackets = described_class[*values]

      expect(via_brackets).to eq(via_new)
      expect(via_new).to have_attributes(
        id: 'Sample#render', symbol_id: 'Sample#render', definition_id: 'Sample#render',
        body_digest: nil, ordinal: 0, kind: :instance_method, file: 'sample.rb', line: 1,
        end_line: 2, defined_via: :def, owner: 'Sample', name: 'render', test: false, visibility: :private
      )
    end

    it 'keeps the complete physical positional constructor compatible' do
      values = [
        'Sample#render', 'Sample#render', 'def:v1:physical', 'body-digest', 2,
        :instance_method, 'sample.rb', 1, 2, :def, 'Sample', 'render', false, :private
      ]

      expect(described_class[*values]).to eq(described_class.new(*values))
      expect(described_class.new(*values)).to have_attributes(
        symbol_id: 'Sample#render', definition_id: 'def:v1:physical', body_digest: 'body-digest', ordinal: 2
      )
    end

    it 'treats block entry nodes as non-method nodes' do
      file_node = node('file:app.rb', kind: :block_entry, owner: nil, name: 'app.rb')

      expect(file_node).not_to be_method
    end
  end

  describe Necropsy::EntryPoint do
    it 'models runtime, test, and external roots with provenance' do
      test_root = Necropsy::EntryPoint.new(node_id: 'spec.rb', reason: :test_suite)
      runtime_root = Necropsy::EntryPoint.new(node_id: 'bin/app', reason: :main_script)
      external_root = Necropsy::Root.new(
        definition_id: 'Library#call', domain: :external, reason: :library_public_api,
        evidence: { 'type' => 'world_policy' }
      )

      expect(test_root).to be_test
      expect(Necropsy::EntryPoint.new('spec.rb', :test_suite)).to eq(test_root)
      expect(runtime_root).to be_runtime
      expect(external_root).to be_external
      expect(external_root.node_id).to eq('Library#call')
      expect(external_root.to_h).to include(
        'node_id' => 'Library#call',
        'definition_id' => 'Library#call',
        'domain' => 'external',
        'evidence' => { 'type' => 'world_policy' }
      )
      expect do
        Necropsy::Root.new(definition_id: 'Library#call', domain: :unknown, reason: :spec)
      end.to raise_error(ArgumentError, /root domain/)
    end
  end

  describe Necropsy::CallSite do
    let(:legacy_values) do
      ['Caller#run', 'render', :implicit, nil, 'lib/caller.rb', 3, false, false, { 'hint' => 'value' }]
    end

    it 'adds a stable identity and physical caller alias to legacy keyword construction' do
      site = described_class.new(
        caller_id: 'Caller#run', message: 'render', receiver_kind: :implicit, receiver_name: nil,
        file: 'lib/caller.rb', line: 3, test: false, dynamic: false, metadata: { 'hint' => 'value' }
      )

      expect(site.call_site_id).to match(/\Acall:v1:[0-9a-f]{64}\z/)
      expect(site.caller_definition_id).to eq('Caller#run')
      expect(site.to_h).to include(
        'call_site_id' => site.call_site_id,
        'caller_id' => 'Caller#run',
        'caller_definition_id' => 'Caller#run'
      )
    end

    it 'keeps legacy and complete positional construction compatible through new and brackets' do
      legacy = described_class.new(*legacy_values)
      complete_values = ['call:v1:explicit', *legacy_values]

      expect(described_class[*legacy_values]).to eq(legacy)
      expect(described_class.new(*complete_values)).to have_attributes(
        call_site_id: 'call:v1:explicit', caller_id: 'Caller#run', message: 'render'
      )
      expect(described_class[*complete_values]).to eq(described_class.new(*complete_values))
    end
  end

  describe Necropsy::Finding do
    it 'orders confidence levels and serializes evidence' do
      result = finding(confidence: :medium, classification: :unused)

      expect(result.at_least?(:low)).to eq(true)
      expect(result.at_least?(:high)).to eq(false)
      expect(result.to_h).to include(
        'classification' => 'unused',
        'confidence' => 'medium',
        'score' => 0.8
      )
      expect(result.to_h.fetch('evidences').first).to include('analyzer' => 'spec')
    end
  end

  describe Necropsy::AnalyzerResult do
    it 'provides an empty result object' do
      result = described_class.empty

      expect(result.edge_evidences).to eq([])
      expect(result.alive_evidences).to eq([])
      expect(result.uncertainties).to eq({})
      expect(result.observation).to eq({})
      expect(result.blockers).to eq([])
      expect(result.resolutions).to eq([])
      expect(result.evidences).to eq([])
    end

    it 'keeps legacy custom analyzer construction compatible' do
      result = described_class.new(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {})

      expect(result.blockers).to eq([])
      expect(result.resolutions).to be_nil
      expect(result.evidences).to eq([])
    end
  end

  describe Necropsy::ScanResult do
    it 'keeps construction without source completeness fields compatible' do
      result = scan_result(nodes: [])

      expect(result.file_statuses).to eq({})
      expect(result.source_errors).to eq([])
    end
  end

  describe Necropsy::SourceError do
    it 'serializes its source location and diagnostic type' do
      error = described_class.new(file: 'lib/sample.rb', line: 3, message: 'unexpected token', type: :parse_error)

      expect(error.to_h).to eq(
        'file' => 'lib/sample.rb', 'line' => 3, 'message' => 'unexpected token', 'type' => 'parse_error'
      )
    end
  end

  describe Necropsy::Blocker do
    it 'serializes scope, source, action, and call-site metadata' do
      blocker = described_class.new(
        kind: :unknown_dispatch,
        scope_kind: :message,
        scope_value: 'render',
        source: :name_resolution,
        reason: 'receiver is unknown',
        metadata: { 'message' => 'render', 'caller_domain' => 'test', 'file' => 'spec/sample_spec.rb', 'line' => 4 }
      )

      expect(blocker).to have_attributes(message: 'render', caller_domain: :test)
      expect(blocker.to_h).to include(
        'kind' => 'unknown_dispatch',
        'scope_kind' => 'message',
        'source' => 'name_resolution',
        'suggested_action' => 'review'
      )
    end
  end
end
