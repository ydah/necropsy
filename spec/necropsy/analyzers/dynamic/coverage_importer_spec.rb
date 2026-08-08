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
      emitted = [*result.alive_evidences.map(&:evidence), *result.edge_evidences.map(&:evidence)]
      expect(emitted.map(&:grade)).to all(eq(:observed))
      expect(emitted.map(&:producer)).to all(eq(:coverage))
      expect(emitted.map(&:producer_version)).to all(eq(Necropsy::VERSION))
      expect(emitted.map(&:source)).to all(include('type' => 'coverage'))
      expect(result.evidences).to contain_exactly(*emitted)
      expect(result.resolutions).to eq([])
      expect(described_class.new({}).profile).to have_attributes(
        version: Necropsy::VERSION,
        assumptions: ['positive_observations_only']
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

  it 'normalizes observation schema v2 provenance and quality fields' do
    payload = {
      'schema_version' => 2,
      'collector' => { 'name' => 'necropsy-coverage', 'version' => '2' },
      'source' => { 'git_sha' => 'abc123', 'tree_digest' => 'sha256:tree' },
      'scope' => { 'environment' => 'production', 'sample_unit' => 'process', 'sample_rate' => 0.5 },
      'quality' => { 'dropped_events' => 2, 'overflowed' => true },
      'nodes' => ['Sample#v2']
    }

    with_project(files: { 'coverage.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverage.yml').analyze(nil, project_for(root))
      observation = result.observation.fetch('coverage')

      expect(observation).to include(
        'schema_version' => 2,
        'collector_name' => 'necropsy-coverage',
        'collector_version' => '2',
        'source_revision' => 'abc123',
        'environment' => 'production',
        'sample_unit' => 'process',
        'sample_rate' => 0.5,
        'quality' => { 'dropped_events' => 2, 'overflowed' => true }
      )
    end
  end

  it 'prefers structured node and edge references while preserving distinct locations' do
    first = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 2 }
    second = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/b.rb', 'line' => 3 }
    target = { 'definition_id' => 'def:v1:target', 'symbol_id' => 'Target#call' }
    payload = {
      'nodes' => ['Reopened#run'],
      'node_references' => [first, second],
      'edges' => [{ 'caller_id' => 'Reopened#run', 'callee_id' => 'Target#call' }],
      'edge_references' => [
        { 'caller_id' => first, 'callee_id' => target },
        { 'caller_id' => second, 'callee_id' => target }
      ]
    }

    with_project(files: { 'coverage.json' => payload.to_json }) do |root|
      result = described_class.new('source' => 'coverage.json').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first, second)
      expect(result.edge_evidences.map(&:caller_id)).to contain_exactly(first, second)
      expect(result.edge_evidences.map(&:callee_id)).to eq([target, target])
      expect(result.edge_evidences.first.evidence.metadata).to include(
        'caller_reference' => first,
        'callee_reference' => target
      )
    end
  end

  it 'retains malformed structured references as unmatched evidence with a diagnostic' do
    malformed = { 'file' => 'lib/missing_symbol.rb', 'line' => 'not-a-line' }

    with_project(files: { 'coverage.yml' => { 'node_references' => [malformed] }.to_yaml }) do |root|
      result = described_class.new('source' => 'coverage.yml').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([malformed])
      expect(result.observation.dig('coverage', 'malformed_references')).to include(
        'kind' => 'node', 'reference' => malformed
      )
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
      expect(result.alive_evidences.first.evidence.scope).to include(
        'revision' => 'abc123',
        'environment' => 'production'
      )
      graph = graph_with(nodes: [node('Sample#run')])
      graph.apply_result(result)
      expect(graph.alive_evidences('Sample#run', projection: :exact, scope: { revision: 'abc123' })).not_to be_empty
      expect(graph.alive_evidences('Sample#run', projection: :exact, scope: { revision: 'other' })).to be_empty
    end
  end

  it 'does not project mismatched source revisions into exact liveness' do
    with_project(files: { 'coverage.yml' => {
      'schema_version' => 2,
      'source' => { 'git_sha' => 'old' },
      'node_references' => [{ 'symbol_id' => 'Sample#run' }]
    }.to_yaml }) do |root|
      sample = node('Sample#run')
      graph = graph_with(nodes: [sample])
      result = described_class.new(
        'source' => 'coverage.yml', 'expected_source_revision' => 'current'
      ).analyze(graph, project_for(root))

      graph.apply_result(result)

      expect(result.observation.dig('coverage', 'source_revision_status')).to eq('mismatch')
      expect(graph.alive_evidences(sample.id, projection: :exact, scope: { revision: 'old' })).to be_empty
      expect(graph).to be_dynamic_alive(sample.id)
    end
  end

  it 'does not treat a scope-only revision as source revision provenance' do
    payload = {
      'nodes' => ['Sample#run'],
      'observation' => { 'scope' => { 'revision' => 'spoofed', 'workload' => 'nightly' } }
    }

    with_project(files: { 'coverage.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverage.yml').analyze(nil, project_for(root))

      expect(result.alive_evidences.first.evidence.scope).to include('workload' => 'nightly')
      expect(result.alive_evidences.first.evidence.scope).not_to have_key('revision')
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
