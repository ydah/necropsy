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

  it 'uses low-weight evidence for bounded ambiguous fallbacks' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    first = node('First#render', owner: 'First', name: 'render')
    second = node('Second#render', owner: 'Second', name: 'render')
    site = call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown)
    graph = graph_with(nodes: [caller, first, second], call_sites: [site], ambiguity_limit: 2)

    result = described_class.new.analyze(graph, nil)

    expect(result.edge_evidences.map(&:callee_id)).to contain_exactly(first.id, second.id)
    expect(result.edge_evidences.map { |edge| edge.evidence.weight }).to all(eq(0.35))
  end

  it 'resolves each call site only once' do
    caller = node('Sample#caller', name: 'caller')
    callee = node('Sample#callee', name: 'callee')
    site = call_site(caller_id: caller.id, message: 'callee')
    graph = graph_with(nodes: [caller, callee], call_sites: [site])
    allow(graph).to receive(:resolve_call_site).and_call_original

    described_class.new.analyze(graph, nil)

    expect(graph).to have_received(:resolve_call_site).once
  end
end
