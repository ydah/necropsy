# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::TracePointImporter do
  it 'uses the TracePoint analyzer profile while importing Coverage-shaped payloads' do
    with_project(files: { 'trace.yml' => { 'nodes' => ['Sample#trace'] }.to_yaml }) do |root|
      importer = described_class.new('source' => 'trace.yml')
      result = importer.analyze(nil, project_for(root))

      expect(importer.profile.name).to eq(:trace_point)
      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#trace'])
      emitted = result.alive_evidences.first.evidence
      expect(emitted).to have_attributes(
        grade: :observed,
        producer: :trace_point,
        producer_version: Necropsy::VERSION
      )
      expect(emitted.source).to include('type' => 'trace_point')
      expect(result.resolutions).to eq([])
      expect(importer.profile).to have_attributes(
        version: Necropsy::VERSION,
        assumptions: %w[positive_observations_only tracepoint_call_events]
      )
    end
  end

  it 'imports structured trace endpoints without collapsing reopened methods' do
    first = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 2 }
    second = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/b.rb', 'line' => 3 }
    target = { 'symbol_id' => 'Target#call', 'file' => 'lib/target.rb', 'line' => 1 }
    payload = {
      'nodes' => ['Reopened#run'],
      'node_references' => [first, second],
      'edge_references' => [
        { 'caller_id' => first, 'callee_id' => target },
        { 'caller_id' => second, 'callee_id' => target }
      ]
    }

    with_project(files: { 'trace.json' => payload.to_json }) do |root|
      result = described_class.new('source' => 'trace.json').analyze(nil, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first, second)
      expect(result.edge_evidences.map(&:caller_id)).to contain_exactly(first, second)
    end
  end
end
