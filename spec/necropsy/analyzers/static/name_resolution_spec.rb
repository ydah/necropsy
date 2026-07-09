# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Static::NameResolution do
  it 'creates call-edge evidence for resolvable call sites' do
    caller = node('Sample#caller', name: 'caller')
    callee = node('Sample#callee', name: 'callee')
    site = call_site(caller_id: caller.id, message: 'callee', receiver_kind: :implicit)
    graph = graph_with(nodes: [caller, callee], call_sites: [site])

    result = described_class.new.analyze(graph, nil)

    expect(result.edge_evidences.map { |edge| [edge.caller_id, edge.callee_id] }).to eq([[caller.id, callee.id]])
    expect(result.edge_evidences.first.evidence.analyzer).to eq(:name_resolution)
    expect(result.uncertainties).to eq({})
  end

  it 'records uncertainty for unknown receivers that cannot be resolved' do
    caller = node('Sample#caller', name: 'caller')
    site = call_site(caller_id: caller.id, message: 'missing', receiver_kind: :unknown)
    graph = graph_with(nodes: [caller], call_sites: [site])

    result = described_class.new.analyze(graph, nil)

    expect(result.edge_evidences).to eq([])
    expect(result.uncertainties.fetch(caller.id)).to include(match(/Unknown receiver for missing/))
  end
end
