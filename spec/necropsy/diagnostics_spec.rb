# frozen_string_literal: true

RSpec.describe Necropsy::Diagnostics do
  subject(:diagnostics) { described_class.new(report) }

  let(:root_node) { node('file:exe/tool', kind: :block_entry, owner: nil, name: 'exe/tool') }
  let(:alive) { node('Sample#alive', name: 'alive') }
  let(:dead) { node('Sample#dead', name: 'dead') }
  let(:graph) do
    graph_with(
      nodes: [root_node, alive, dead],
      uncertainties: { dead.id => ['Dynamic dispatch nearby'] }
    ).tap do |result|
      result.add_entry_point(root_node.id, :main_script)
      result.add_edge(
        root_node.id,
        alive.id,
        evidence(analyzer: :name_resolution, metadata: { 'file' => 'exe/tool', 'line' => 3 })
      )
      result.add_edge(dead.id, alive.id, evidence)
    end
  end
  let(:reachability) do
    Necropsy::Reachability::Result.new(
      runtime_paths: { root_node.id => nil, alive.id => root_node.id },
      test_paths: {}
    )
  end
  let(:dead_finding) { finding(id: dead.id, classification: :unreachable, confidence: :medium, score: 0.62) }
  let(:report) do
    Necropsy::Report.new(root: '/repo', graph: graph, findings: [dead_finding], reachability: reachability)
  end

  it 'explains an alive node with its shortest evidenced path' do
    payload = diagnostics.why(alive.id)

    expect(payload).to include('status' => 'alive', 'kind' => 'runtime')
    expect(payload.fetch('path').map { |step| step.dig('node', 'id') }).to eq([root_node.id, alive.id])
    expect(payload.dig('path', 1, 'edge', 'evidences', 0)).to include('analyzer' => 'name_resolution')
    expect(diagnostics.render(payload)).to include('Alive (runtime)', 'via name_resolution', 'exe/tool:3')
  end

  it 'explains a dead node with nearby alive nodes and uncertainty' do
    payload = diagnostics.why(dead.id)

    expect(payload).to include('status' => 'dead', 'classification' => 'unreachable')
    expect(payload.fetch('nearest_alive')).to include('node_id' => alive.id, 'distance' => 1)
    expect(payload.fetch('uncertainties')).to include('Dynamic dispatch nearby')
  end

  it 'suggests partial matches for missing IDs' do
    payload = diagnostics.why('Missing#alive')

    expect(payload).to include('status' => 'not_found')
    expect(payload.fetch('suggestions')).to include(alive.id)
  end

  it 'renders score components as human and JSON explanations' do
    payload = diagnostics.explain(dead.id)

    expect(payload).to include('status' => 'finding', 'score' => 0.62)
    expect(diagnostics.render(payload)).to include('base(unreachable)', '+0.62', 'total')
    expect(JSON.parse(diagnostics.render(payload, format: :json))).to include('status' => 'finding')
  end
end
