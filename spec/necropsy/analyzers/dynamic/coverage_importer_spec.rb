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
      expect(result.observation.fetch('coverage')).to include(
        'days' => 12,
        'schema_version' => 1,
        'positive_evidence_policy' => 'alive_only',
        'source_revision_status' => 'unknown',
        'source_revision_policy' => 'accepted_for_liveness_only'
      )
    end
  end

  it 'imports executed aliases from JSON payloads' do
    with_project(files: { 'coverage.json' => { 'executed' => ['Sample#json'] }.to_json }) do |root|
      result = described_class.new('source' => 'coverage.json').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#json'])
    end
  end

  it 'marks a supplied v1 source revision as unverified while retaining positive evidence' do
    payload = {
      'nodes' => ['Sample#run'],
      'observation' => { 'source_revision' => 'abc123', 'environment' => 'production' }
    }

    with_project(files: { 'coverage.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverage.yml').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#run'])
      expect(result.observation.fetch('coverage')).to include(
        'source_revision' => 'abc123',
        'source_revision_status' => 'provided_unverified',
        'source_revision_policy' => 'accepted_for_liveness_only'
      )
    end
  end

  it 'raises a domain error when the configured source is missing' do
    with_project do |root|
      expect do
        described_class.new('source' => 'missing.yml').analyze(nil, project_for(root))
      end.to raise_error(Necropsy::Error, /Coverage source does not exist/)
    end
  end
end
