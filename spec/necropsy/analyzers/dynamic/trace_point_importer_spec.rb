# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::TracePointImporter do
  it 'uses the TracePoint analyzer profile while importing Coverage-shaped payloads' do
    with_project(files: { 'trace.yml' => { 'nodes' => ['Sample#trace'] }.to_yaml }) do |root|
      importer = described_class.new('source' => 'trace.yml')
      result = importer.analyze(nil, project_for(root))

      expect(importer.profile.name).to eq(:trace_point)
      expect(result.alive_evidences.map(&:node_id)).to eq(['Sample#trace'])
    end
  end
end
