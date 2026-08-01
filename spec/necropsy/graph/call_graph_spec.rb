# frozen_string_literal: true

RSpec.describe Necropsy::CallGraph do
  it 'deduplicates entry points and ignores unknown nodes' do
    graph = graph_with(nodes: [node('Sample#run')])

    graph.add_entry_point('Sample#run', :main_script)
    graph.add_entry_point('Sample#run', :main_script)
    graph.add_entry_point('Missing#run', :main_script)

    expect(graph.entry_points.map(&:node_id)).to eq(['Sample#run'])
  end

  it 'applies analyzer results only for known graph nodes' do
    caller = node('Sample#caller', name: 'caller')
    callee = node('Sample#callee', name: 'callee')
    graph = graph_with(nodes: [caller, callee])
    result = analyzer_result(
      edge_evidences: [
        Necropsy::EdgeEvidence.new(caller_id: caller.id, callee_id: callee.id, evidence: evidence),
        Necropsy::EdgeEvidence.new(caller_id: caller.id, callee_id: 'Missing#callee', evidence: evidence)
      ],
      alive_evidences: [
        Necropsy::AliveEvidence.new(node_id: callee.id, evidence: evidence(kind: :alive)),
        Necropsy::AliveEvidence.new(node_id: 'Missing#alive', evidence: evidence(kind: :alive))
      ],
      uncertainties: { caller.id => ['dynamic dispatch'] },
      observation: { 'coverage' => { 'days' => 10 }, 'trace' => { 'requests' => 2 } }
    )

    graph.apply_result(result)

    expect(graph.edges.map { |edge| [edge.caller_id, edge.callee_id] }).to eq([[caller.id, callee.id]])
    expect(graph.dynamic_alive?(callee.id)).to eq(true)
    expect(graph.dynamic_alive?('Missing#alive')).to eq(false)
    expect(graph.uncertainties(caller.id)).to include('dynamic dispatch')
    expect(graph.observation).to include('coverage' => { 'days' => 10 }, 'trace' => { 'requests' => 2 })
  end

  it 'resolves calls by receiver kind and RTA instantiated classes' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    base = node('Base#render', owner: 'Base', name: 'render')
    child = node('Child#render', owner: 'Child', name: 'render')
    unused = node('Unused#render', owner: 'Unused', name: 'render')
    site = call_site(
      caller_id: caller.id,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Base',
      metadata: { 'receiver_candidates' => ['Base'] }
    )
    graph = graph_with(
      nodes: [caller, base, child, unused],
      call_sites: [site],
      instantiated_classes: Set['Child', 'Missing'],
      class_infos: [
        class_info('Base'),
        class_info('Child', superclass: 'Base'),
        class_info('Unused')
      ]
    )

    expect(graph.instantiated_classes).to eq(Set['Child'])
    expect(graph.resolve_call_site(site).map(&:id)).to eq(['Base#render'])
    expect(graph.resolve_call_site(site, rta: true).map(&:id)).to eq([])
  end

  it 'exports graph state for reports' do
    graph = graph_with(nodes: [node('Sample#run')])
    graph.add_profile(Necropsy::AnalyzerProfile.new(name: :spec, kind: :static, soundness: :partial,
                                                    description: 'spec'))

    expect(graph.to_h).to include(
      'nodes' => [include('id' => 'Sample#run')],
      'edges' => [],
      'entry_points' => [],
      'profiles' => [include('name' => 'spec')]
    )
  end

  it 'does not enable absence-based classification when all dynamic node IDs are unknown' do
    graph = graph_with(nodes: [node('Sample#run')])
    result = analyzer_result(
      alive_evidences: [
        Necropsy::AliveEvidence.new(node_id: 'Other#run', evidence: evidence(analyzer: :coverage, kind: :alive))
      ],
      observation: { 'coverage' => { 'days' => 30 } }
    )

    expect { graph.apply_result(result) }.to output(/none matched the scanned project/).to_stderr
    expect(graph).not_to be_dynamic_enabled
  end

  it 'indexes incoming edges without mutating empty graph buckets during reads' do
    caller = node('Sample#caller', name: 'caller')
    callee = node('Sample#callee', name: 'callee')
    graph = graph_with(nodes: [caller, callee])
    graph.add_edge(caller.id, callee.id, evidence)

    expect(graph.incoming_edges(callee.id).map(&:caller_id)).to eq([caller.id])
    expect(graph.edges_from('Missing#node')).to eq({})
    expect(graph.uncertainties('Missing#node')).to eq([])
    expect(graph.edges.length).to eq(1)
  end

  it 'invalidates method and dispatch indexes when a node is added' do
    graph = graph_with(nodes: [], class_infos: [class_info('Sample')])

    expect(graph.candidate_nodes('run')).to eq([])
    expect(graph.send(:dispatched_instance_owner, 'Sample', 'run')).to be_nil

    added = node('Sample#run', owner: 'Sample', name: 'run')
    graph.add_node(added)

    expect(graph.candidate_nodes('run')).to eq([added])
    expect(graph.send(:dispatched_instance_owner, 'Sample', 'run')).to eq('Sample')
  end

  it 'resolves super calls to the nearest ancestor implementation' do
    parent = node('Parent#render', owner: 'Parent', name: 'render')
    child = node('Child#render', owner: 'Child', name: 'render')
    site = call_site(caller_id: child.id, message: 'render', receiver_kind: :super, receiver_name: 'Child')
    graph = graph_with(
      nodes: [parent, child],
      call_sites: [site],
      class_infos: [class_info('Parent'), class_info('Child', superclass: 'Parent')]
    )

    expect(graph.resolve_call_site(site).map(&:id)).to eq(['Parent#render'])
    expect(graph.resolve_call_site(site, rta: true).map(&:id)).to eq(['Parent#render'])
  end

  it 'uses RTA results to remove broader standard static edges for the same call site' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    base = node('Base#render', owner: 'Base', name: 'render')
    live = node('Live#render', owner: 'Live', name: 'render')
    dead = node('Dead#render', owner: 'Dead', name: 'render')
    site = call_site(
      caller_id: caller.id,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Base',
      metadata: { 'receiver_candidates' => ['Base'] }
    )
    graph = graph_with(
      nodes: [caller, base, live, dead],
      call_sites: [site],
      instantiated_classes: Set['Live'],
      class_infos: [
        class_info('Base'),
        class_info('Live', superclass: 'Base'),
        class_info('Dead', superclass: 'Base')
      ]
    )
    [Necropsy::Analyzers::Static::NameResolution.new, Necropsy::Analyzers::Static::CHA.new].each do |analyzer|
      graph.apply_result(analyzer.analyze(graph, nil))
    end
    result = Necropsy::Analyzers::Static::RTA.new.analyze(graph, nil)
    graph.apply_result(result)
    graph.reconcile_rta_result(result)

    expect(graph.edges.map(&:callee_id)).to eq(['Live#render'])
    expect(graph.incoming_edges(live.id).flat_map(&:evidences).map(&:analyzer)).to contain_exactly(:cha, :rta)
  end
end
