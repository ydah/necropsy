# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::CoverbandImporter do
  it 'marks methods alive from explicit node ids' do
    live = node('Sample#live', file: 'app/sample.rb', line: 5, end_line: 7)
    dead = node('Sample#dead', file: 'app/sample.rb', line: 10, end_line: 12)
    graph = graph_with(nodes: [live, dead])
    payload = { 'nodes' => [live.id], 'observation' => { 'days' => 30 } }

    with_project(files: { 'coverband.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([live.id])
      expect(result.observation).to eq('coverband' => { 'days' => 30 })
    end
  end

  it 'maps line-count arrays and hashes back to methods by relative file' do
    first = node('Sample#first', file: 'app/sample.rb', line: 2, end_line: 4)
    second = node('Sample#second', file: 'app/sample.rb', line: 8, end_line: 10)
    graph = graph_with(nodes: [first, second])
    payload = {
      'files' => {
        'app/sample.rb' => [0, 1, 0, 0, 0, 0, 0, 2],
        '/repo/app/other.rb' => { '9' => 1 }
      }
    }

    with_project(files: { 'coverband.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first.id, second.id)
    end
  end

  it 'accepts root-level file coverage maps without a files wrapper' do
    live = node('Sample#live', file: 'app/sample.rb', line: 3, end_line: 3)
    graph = graph_with(nodes: [live])

    with_project(files: { 'coverband.yml' => { './app/sample.rb' => { '3' => 1 } }.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([live.id])
    end
  end
end
