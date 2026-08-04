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

  it 'materializes bounded fallback candidates and blocks larger candidate sets' do
    [1, 4, 5, 100].each do |count|
      caller = node("Caller#{count}#run", owner: "Caller#{count}", name: 'run')
      candidates = count.times.map { |index| node("Target#{index}#render", owner: "Target#{index}", name: 'render') }
      site = call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown, line: count)
      graph = graph_with(nodes: [caller, *candidates], call_sites: [site], ambiguity_limit: 4)

      result = described_class.new.analyze(graph, nil)

      if count <= 4
        expect(result.edge_evidences.length).to eq(count)
        expect(result.blockers).to eq([])
      else
        expect(result.edge_evidences).to eq([])
        expect(result.blockers.one?).to eq(true)
        expect(result.blockers.first.metadata).to include(
          'candidate_count' => count,
          'ambiguity_limit' => 4,
          'reason_code' => 'ambiguity_limit_exceeded'
        )
      end
    end
  end

  it 'keeps unlimited resolution conservative without adding a blocker' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    candidates = 100.times.map { |index| node("Target#{index}#render", owner: "Target#{index}", name: 'render') }
    site = call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown)
    graph = graph_with(nodes: [caller, *candidates], call_sites: [site], ambiguity_limit: Float::INFINITY)

    result = described_class.new.analyze(graph, nil)

    expect(result.edge_evidences.length).to eq(100)
    expect(result.blockers).to eq([])
  end

  it 'records caller, receiver hints, scope, location, and domain for an unresolved dispatch' do
    caller = node('Billing::Router#route', owner: 'Billing::Router', name: 'route')
    site = call_site(
      caller_id: caller.id,
      message: 'call',
      receiver_kind: :instance,
      receiver_name: 'Billing::Handler',
      file: 'app/billing/router.rb',
      line: 17,
      metadata: { 'receiver_candidates' => ['Billing::Handler'] }
    )
    candidates = 5.times.map { |index| node("Other#{index}#call", owner: "Other#{index}", name: 'call') }
    graph = graph_with(nodes: [caller, *candidates], call_sites: [site], ambiguity_limit: 4)

    blocker = described_class.new.analyze(graph, nil).blockers.fetch(0)

    expect(blocker).to have_attributes(scope_kind: :owner, scope_value: ['Billing::Handler'])
    expect(blocker.metadata).to include(
      'caller_id' => caller.id,
      'caller_domain' => 'runtime',
      'message' => 'call',
      'receiver_kind' => 'instance',
      'receiver_hints' => ['Billing::Handler'],
      'owner_scope' => ['Billing::Handler'],
      'namespace_scope' => ['Billing'],
      'file' => 'app/billing/router.rb',
      'line' => 17,
      'candidate_count' => 5
    )
  end

  it 'retains an unknown-receiver blocker even when no definition currently has the message' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    site = call_site(caller_id: caller.id, message: 'missing', receiver_kind: :unknown, test: true)
    graph = graph_with(nodes: [caller], call_sites: [site])

    blocker = described_class.new.analyze(graph, nil).blockers.fetch(0)

    expect(blocker).to have_attributes(scope_kind: :message, scope_value: 'missing')
    expect(blocker.metadata).to include(
      'caller_domain' => 'test', 'candidate_count' => 0, 'reason_code' => 'unknown_receiver'
    )
  end
end
