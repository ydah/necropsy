# frozen_string_literal: true

RSpec.describe Necropsy::EvidenceStore do
  def graded_evidence(id:, grade:, producer:, details: producer.to_s, scope: { 'revision' => 'abc' })
    Necropsy::Evidence.new(
      analyzer: producer,
      kind: :call_edge,
      weight: 1.0,
      details: details,
      metadata: {},
      evidence_id: id,
      producer: producer,
      producer_version: '1',
      grade: grade,
      relation: :call_edge,
      source: { 'type' => 'spec' },
      assumptions: ['fixture'],
      scope: scope
    )
  end

  def edge_graph
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Target#call', owner: 'Target', name: 'call')
    [graph_with(nodes: [caller, target]), caller, target]
  end

  it 'interns one physical edge with multiple grades and producers' do
    graph, caller, target = edge_graph
    exact = graded_evidence(id: 'evidence:v1:exact', grade: :exact, producer: :literal)
    conservative = graded_evidence(
      id: 'evidence:v1:conservative', grade: :conservative, producer: :cha
    )
    graph.add_edge(caller.graph_id, target.graph_id, conservative)
    graph.add_edge(caller.graph_id, target.graph_id, exact)

    expect(graph.evidence_records).to contain_exactly(exact, conservative)
    expect(graph.edge_relations(projection: :conservative).first.evidence_ids).to eq(
      %w[evidence:v1:conservative evidence:v1:exact]
    )
    expect(graph.edges(projection: :exact).first.evidences).to eq([exact])
    expect(graph.edges_from(caller.graph_id, projection: :exact).fetch(target.graph_id)).to eq([exact])
  end

  it 'stores detached analyzer evidence for resolution provenance' do
    graph, = edge_graph
    record = graded_evidence(id: 'evidence:v1:detached', grade: :heuristic, producer: :flow)

    graph.apply_result(analyzer_result(evidences: [record]))

    expect(graph.evidence_record(record.evidence_id)).to eq(record)
    expect(graph.edges).to eq([])
  end

  it 'stores evidence whose edge endpoints cannot be materialized' do
    graph, caller, = edge_graph
    record = graded_evidence(id: 'evidence:v1:unmatched', grade: :observed, producer: :trace)

    expect(graph.add_edge(caller.graph_id, 'Missing#call', record)).to eq(false)

    expect(graph.evidence_record(record.evidence_id)).to eq(record)
    expect(graph.edges).to eq([])
  end

  it 'projects observed evidence by scope without deleting conservative evidence' do
    graph, caller, target = edge_graph
    conservative = graded_evidence(
      id: 'evidence:v1:may', grade: :conservative, producer: :cha, scope: { 'world' => 'application' }
    )
    observed = graded_evidence(
      id: 'evidence:v1:observed', grade: :observed, producer: :trace,
      scope: { 'revision' => 'abc', 'workload' => 'production' }
    )
    graph.add_edge(caller.graph_id, target.graph_id, conservative)
    graph.add_edge(caller.graph_id, target.graph_id, observed)

    expect(graph.edges(projection: :conservative).first.evidences).to contain_exactly(conservative, observed)
    expect(graph.edges(projection: :observed).first.evidences).to eq([observed])
    expect(graph.edges(projection: :observed, scope: { 'workload' => 'production' }).first.evidences).to eq(
      [observed]
    )
    expect(graph.edges(projection: :observed, scope: { 'workload' => 'staging' })).to eq([])
    expect(graph.edges(projection: :observed, scope: { 'missing' => nil })).to eq([])
    expect(graph.edges(projection: :exact)).to eq([])
    expect(graph.edges(projection: :exact, scope: { 'revision' => 'abc' }).first.evidences).to eq([observed])
  end

  it 'keeps grade-less legacy evidence only in the conservative projection regardless of weight' do
    graph, caller, target = edge_graph
    legacy = evidence(weight: 100.0)
    graph.add_edge(caller.graph_id, target.graph_id, legacy)

    expect(graph.edges(projection: :conservative).length).to eq(1)
    expect(graph.edges(projection: :exact)).to eq([])
    expect(graph.edges(projection: :observed)).to eq([])
    expect(graph.evidence_records.first).to have_attributes(grade: nil, weight: 100.0)
  end

  it 'stores unknown relations as blockers without materializing edges' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Target#call', owner: 'Target', name: 'call')
    site = call_site(caller_id: caller.graph_id, message: 'call', call_site_id: 'call:v1:unknown-relation')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    record = Necropsy::ResolutionRecord.new(
      resolution: Necropsy::Resolution.new(
        call_site_id: site.call_site_id,
        target_definition_ids: [],
        status: :unknown,
        unknown_scope: Necropsy::UnknownScope.new(scope_kind: :message, scope_value: 'call', match: :exact)
      ),
      producer: :flow,
      producer_version: '1',
      assumptions: ['unknown receiver']
    )

    graph.apply_result(analyzer_result(resolutions: [record]))

    expect(graph.edges).to eq([])
    expect(graph.edge_relations).to eq([])
    expect(graph.matching_blockers(target).map(&:kind)).to eq([:unknown_dispatch])
  end

  it 'quarantines colliding evidence IDs deterministically and fails closed' do
    snapshots = [
      %w[first second],
      %w[second first]
    ].map do |order|
      graph, caller, target = edge_graph
      records = {
        'first' => graded_evidence(
          id: 'evidence:v1:collision', grade: :exact, producer: :first, details: 'first payload'
        ),
        'second' => graded_evidence(
          id: 'evidence:v1:collision', grade: :exact, producer: :second, details: 'second payload'
        )
      }
      order.each { |name| graph.add_edge(caller.graph_id, target.graph_id, records.fetch(name)) }

      expect(graph.edges).to eq([])
      expect(graph.evidence_records).to eq([])
      expect(graph.matching_blockers(target).map(&:kind)).to eq([:evidence_collision])
      {
        collisions: graph.evidence_collisions,
        blockers: graph.blockers.map(&:to_h),
        observation: graph.observation.fetch('evidence_store')
      }
    end

    expect(snapshots.first).to eq(snapshots.last)
  end

  it 'keeps multiple collision blockers and diagnostics deterministic' do
    collision_ids = %w[evidence:v1:alpha-collision evidence:v1:beta-collision]
    snapshots = [collision_ids, collision_ids.reverse].map do |ordered_ids|
      graph, caller, target = edge_graph
      ordered_ids.each do |evidence_id|
        graph.add_edge(
          caller.graph_id,
          target.graph_id,
          graded_evidence(id: evidence_id, grade: :exact, producer: :first)
        )
        graph.add_edge(
          caller.graph_id,
          target.graph_id,
          graded_evidence(id: evidence_id, grade: :exact, producer: :second)
        )
      end
      valid = graded_evidence(id: 'evidence:v1:valid', grade: :exact, producer: :literal)
      graph.add_edge(caller.graph_id, target.graph_id, valid)

      expect(graph.observation.fetch('evidence_store')).to include(
        'record_count' => 1,
        'collision_count' => 2
      )
      expect(graph.blockers.select { |blocker| blocker.kind == :evidence_collision }.length).to eq(2)
      graph.to_h.slice('blockers', 'evidence_records', 'evidence_collisions', 'observation')
    end

    expect(snapshots.first).to eq(snapshots.last)
  end

  it 'orders physical relations and evidence IDs independently of insertion order' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    first = node('First#call', owner: 'First', name: 'call')
    second = node('Second#call', owner: 'Second', name: 'call')
    records = [
      [second, graded_evidence(id: 'evidence:v1:zeta', grade: :conservative, producer: :zeta)],
      [first, graded_evidence(id: 'evidence:v1:alpha', grade: :exact, producer: :alpha)]
    ]
    snapshots = [records, records.reverse].map do |ordered|
      graph = graph_with(nodes: [caller, first, second])
      ordered.each { |target, record| graph.add_edge(caller.graph_id, target.graph_id, record) }
      graph.to_h.slice('edges', 'edge_relations', 'evidence_records')
    end

    expect(snapshots.first).to eq(snapshots.last)
  end

  it 'preserves nested edge evidence while serializing interned references' do
    graph, caller, target = edge_graph
    record = graded_evidence(id: 'evidence:v1:serialized', grade: :exact, producer: :literal)
    graph.add_edge(caller.graph_id, target.graph_id, record)

    payload = graph.to_h
    expect(payload.fetch('edge_projection')).to eq('conservative')
    expect(payload.fetch('edges').first).to include(
      'evidence_ids' => [record.evidence_id],
      'evidences' => [record.to_h]
    )
    expect(payload.fetch('edge_relations').first).to include(
      'evidence_ids' => [record.evidence_id],
      'projection' => 'conservative'
    )
    expect(payload.fetch('evidence_records')).to eq([record.to_h])
  end

  it 'lets reachability explicitly select conservative or exact edges' do
    root = node('Root#run', owner: 'Root', name: 'run')
    exact_target = node('Exact#call', owner: 'Exact', name: 'call')
    may_target = node('May#call', owner: 'May', name: 'call')
    graph = graph_with(nodes: [root, exact_target, may_target])
    graph.add_entry_point(root.graph_id, :main_script)
    graph.add_edge(
      root.graph_id,
      exact_target.graph_id,
      graded_evidence(id: 'evidence:v1:root-exact', grade: :exact, producer: :literal)
    )
    graph.add_edge(
      root.graph_id,
      may_target.graph_id,
      graded_evidence(id: 'evidence:v1:root-may', grade: :conservative, producer: :cha)
    )

    conservative = Necropsy::Reachability::Engine.new(graph).call
    exact = Necropsy::Reachability::Engine.new(graph, projection: :exact).call

    expect(conservative.runtime_alive).to contain_exactly(root.graph_id, exact_target.graph_id, may_target.graph_id)
    expect(exact.runtime_alive).to contain_exactly(root.graph_id, exact_target.graph_id)
  end

  it 'rejects unknown projection names' do
    graph, = edge_graph

    expect { graph.edges(projection: :guess) }.to raise_error(ArgumentError, /projection/)
    expect do
      Necropsy::Reachability::Engine.new(graph, projection: :guess)
    end.to raise_error(ArgumentError, /projection/)
  end
end
