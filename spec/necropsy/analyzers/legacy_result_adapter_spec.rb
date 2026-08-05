# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::LegacyResultAdapter do
  def profile(kind: :static)
    Necropsy::AnalyzerProfile.new(
      name: :legacy_custom,
      kind: kind,
      soundness: :partial,
      description: 'legacy custom analyzer',
      version: '2',
      assumptions: ['legacy_contract']
    )
  end

  def adapt(graph, result, kind: :static)
    described_class.new(graph: graph, profile: profile(kind: kind)).adapt(result)
  end

  def legacy_edge(site, target_id, weight: 1.0, metadata: site.to_h.except('call_site_id'))
    Necropsy::EdgeEvidence.new(
      caller_id: site.caller_id,
      callee_id: target_id,
      evidence: evidence(analyzer: :legacy_custom, weight: weight, metadata: metadata)
    )
  end

  it 'adapts a uniquely matched legacy target to a partial resolution' do
    caller = node('Caller#run')
    target = node('Target#call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:legacy-target')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    edge = legacy_edge(site, target.graph_id)

    adapted = adapt(graph, analyzer_result(edge_evidences: [edge]))
    record = adapted.resolutions.fetch(0)

    expect(record).to have_attributes(
      producer: 'legacy_custom', producer_version: '2', assumptions: ['legacy_contract']
    )
    expect(record.resolution).to have_attributes(
      call_site_id: site.call_site_id,
      target_definition_ids: [target.graph_id],
      status: :partial
    )
    expect(adapted.edge_evidences).to eq([edge])
  end

  it 'adapts a legacy empty result to unknown without using evidence weight' do
    caller = node('Caller#run')
    target = node('Target#call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:weight')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    low = adapt(graph, analyzer_result(edge_evidences: [legacy_edge(site, target.graph_id, weight: 0.01)]))
    high = adapt(graph, analyzer_result(edge_evidences: [legacy_edge(site, target.graph_id, weight: 100.0)]))
    empty = adapt(graph, analyzer_result)

    expect(low.resolutions.first.resolution.status).to eq(:partial)
    expect(high.resolutions.first.resolution.status).to eq(:partial)
    expect(empty.resolutions.first.resolution).to have_attributes(
      target_definition_ids: [], status: :unknown
    )
  end

  it 'prioritizes a call-site ID over absent legacy fields' do
    caller = node('Caller#run')
    target = node('Target#call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:id-priority')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    edge = legacy_edge(site, target.graph_id, metadata: { 'call_site_id' => site.call_site_id })

    resolution = adapt(graph, analyzer_result(edge_evidences: [edge])).resolutions.first.resolution

    expect(resolution).to have_attributes(target_definition_ids: [target.graph_id], status: :partial)
  end

  it 'does not guess when legacy call-site fields match more than one physical site' do
    caller = node('Caller#run')
    target = node('Target#call')
    first = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:first')
    second = first.with(call_site_id: 'call:v1:second')
    graph = graph_with(nodes: [caller, target], call_sites: [first, second])

    adapted = adapt(graph, analyzer_result(edge_evidences: [legacy_edge(first, target.graph_id)]))

    expect(adapted.resolutions.map { |record| record.resolution.status }).to eq(%i[unknown unknown])
    expect(adapted.resolutions.flat_map { |record| record.resolution.target_definition_ids }).to eq([])
  end

  it 'does not guess a physical target from an ambiguous logical symbol' do
    caller = node('Caller#run')
    first_target = node('Target#call', definition_id: 'def:v1:first', symbol_id: 'Target#call')
    second_target = node('Target#call', definition_id: 'def:v1:second', symbol_id: 'Target#call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:ambiguous-target')
    graph = graph_with(nodes: [caller, first_target, second_target], call_sites: [site])

    resolution = adapt(
      graph,
      analyzer_result(edge_evidences: [legacy_edge(site, 'Target#call')])
    ).resolutions.first.resolution

    expect(resolution).to have_attributes(target_definition_ids: [], status: :unknown)
  end

  it 'leaves dynamic and explicitly native results unchanged' do
    graph = graph_with(nodes: [])
    observed = Necropsy::AliveEvidence.new(node_id: 'Observed#run', evidence: evidence(kind: :alive))
    legacy_dynamic = analyzer_result(alive_evidences: [observed])
    native = analyzer_result(resolutions: [])

    expect(adapt(graph, legacy_dynamic, kind: :dynamic)).to equal(legacy_dynamic)
    expect(adapt(graph, native)).to equal(native)
    expect(legacy_dynamic.resolutions).to be_nil
    expect(legacy_dynamic.alive_evidences).to eq([observed])
  end

  it 'collects existing, edge, and alive evidence additively in deterministic order' do
    caller = node('Caller#run')
    target = node('Target#call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:evidence')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    existing = evidence(analyzer: :existing, kind: :alive)
    edge = legacy_edge(site, target.graph_id)
    alive_record = evidence(analyzer: :legacy_custom, kind: :alive)
    alive = Necropsy::AliveEvidence.new(node_id: target.graph_id, evidence: alive_record)
    result = analyzer_result(edge_evidences: [edge], alive_evidences: [alive], evidences: [existing])

    forward = adapt(graph, result)
    reverse = adapt(graph, result.with(evidences: [existing], edge_evidences: [edge].reverse))

    expect(forward.evidences).to contain_exactly(existing, edge.evidence, alive_record)
    expect(reverse.evidences).to eq(forward.evidences)
    expect(forward.alive_evidences).to eq([alive])
  end

  it 'orders adapted records and collected evidence independently of legacy edge order' do
    caller = node('Caller#run')
    first_target = node('First#call')
    second_target = node('Second#save')
    first_site = call_site(caller_id: caller.graph_id, message: 'call', line: 2)
    second_site = call_site(caller_id: caller.graph_id, message: 'save', line: 3)
    graph = graph_with(nodes: [caller, first_target, second_target], call_sites: [second_site, first_site])
    edges = [legacy_edge(first_site, first_target.graph_id), legacy_edge(second_site, second_target.graph_id)]

    forward = adapt(graph, analyzer_result(edge_evidences: edges))
    reverse = adapt(graph, analyzer_result(edge_evidences: edges.reverse))

    expect(reverse.resolutions).to eq(forward.resolutions)
    expect(reverse.evidences).to eq(forward.evidences)
  end
end
