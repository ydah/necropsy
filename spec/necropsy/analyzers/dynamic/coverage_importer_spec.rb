# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::CoverageImporter do
  it 'returns an empty result without a configured source' do
    with_project do |root|
      result = described_class.new({}).analyze(nil, project_for(root))

      expect(result).to eq(Necropsy::AnalyzerResult.empty)
    end
  end

  it 'imports executed nodes and observed edges from YAML payloads' do
    payload = {
      'nodes' => ['Sample#run'],
      'edges' => [{ 'caller_id' => 'Sample#run', 'callee_id' => 'Sample#helper' }],
      'observation' => { 'days' => 12 }
    }

    with_project(files: { 'coverage.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverage.yml').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#run'])
      expect(result.edge_evidences.map { |edge| [edge.caller_id, edge.callee_id] }).to eq(
        [['Sample#run', 'Sample#helper']]
      )
      expect(result.observation).to eq('coverage' => { 'days' => 12 })
    end
  end

  it 'imports executed aliases from JSON payloads' do
    with_project(files: { 'coverage.json' => { 'executed' => ['Sample#json'] }.to_json }) do |root|
      result = described_class.new('source' => 'coverage.json').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#json'])
    end
  end
end
