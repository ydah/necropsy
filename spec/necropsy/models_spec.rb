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
        'kind' => 'instance_method',
        'line' => 10,
        'end_line' => 12,
        'defined_via' => 'define_method'
      )
    end

    it 'treats block entry nodes as non-method nodes' do
      file_node = node('file:app.rb', kind: :block_entry, owner: nil, name: 'app.rb')

      expect(file_node).not_to be_method
    end
  end

  describe Necropsy::EntryPoint do
    it 'distinguishes test-suite roots from runtime roots' do
      expect(Necropsy::EntryPoint.new(node_id: 'spec.rb', reason: :test_suite)).to be_test
      expect(Necropsy::EntryPoint.new(node_id: 'bin/app', reason: :main_script)).not_to be_test
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
    end

    it 'keeps legacy custom analyzer construction compatible' do
      result = described_class.new(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {})

      expect(result.blockers).to eq([])
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
