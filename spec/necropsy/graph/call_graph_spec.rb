# frozen_string_literal: true

RSpec.describe Necropsy::CallGraph do
  def unresolved_blocker(message:, scope_kind: :message, scope_value: message, domain: :runtime,
                         receiver_kind: :unknown, caller_kind: :instance_method, original_message: nil,
                         include_private: nil)
    metadata = {
      'message' => message,
      'caller_domain' => domain.to_s,
      'receiver_kind' => receiver_kind.to_s,
      'caller_kind' => caller_kind.to_s,
      'original_message' => original_message,
      'file' => 'app/router.rb',
      'line' => 8
    }
    metadata['include_private'] = include_private unless include_private.nil?
    Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: scope_kind,
      scope_value: scope_value,
      source: :name_resolution,
      reason: 'target set is incomplete',
      suggested_action: :review_receiver_flow,
      metadata: metadata
    )
  end

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

    expect { graph.apply_result(result) }.to output(
      /matched 1 of 2 dynamic node IDs.*fully matched 1 of 2 dynamic edges; partially matched 1; unmatched 0/m
    ).to_stderr

    expect(graph.edges.map { |edge| [edge.caller_id, edge.callee_id] }).to eq([[caller.id, callee.id]])
    expect(graph.dynamic_alive?(callee.id)).to eq(true)
    expect(graph.dynamic_alive?('Missing#alive')).to eq(false)
    expect(graph.uncertainties(caller.id)).to include('dynamic dispatch')
    expect(graph.observation).to include('coverage' => { 'days' => 10 }, 'trace' => { 'requests' => 2 })
    expect(graph.dynamic_evidence_diagnostic).to include(
      'attempted' => { 'nodes' => 2, 'edges' => 2 },
      'matched' => { 'nodes' => 1, 'edges' => 1 },
      'partially_matched' => { 'nodes' => 0, 'edges' => 1 },
      'unmatched' => { 'nodes' => 1, 'edges' => 0 },
      'unmatched_samples' => {
        'nodes' => ['Missing#alive'],
        'edges' => ['Sample#caller -> Missing#callee (unmatched callee: Missing#callee)']
      }
    )
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

  it 'resolves bounded ambiguous fallbacks conservatively' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    first = node('First#render', owner: 'First', name: 'render')
    second = node('Second#render', owner: 'Second', name: 'render')
    site = call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown)
    nodes = [caller, first, second]

    strict = graph_with(nodes: nodes, call_sites: [site], ambiguity_limit: 1)
    conservative = graph_with(nodes: nodes, call_sites: [site], ambiguity_limit: 2)

    expect(strict.resolve_call_site(site)).to eq([])
    expect(conservative.resolve_call_site(site)).to contain_exactly(first, second)
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

    expect { graph.apply_result(result) }.to output(/matched 0 of 1 dynamic node IDs/).to_stderr
    expect(graph).not_to be_dynamic_enabled
    expect(graph).to be_dynamic_observation
  end

  it 'uses observed dynamic edges as positive liveness evidence' do
    caller = node('Sample#caller', name: 'caller')
    callee = node('Sample#callee', name: 'callee')
    graph = graph_with(nodes: [caller, callee])
    result = analyzer_result(
      edge_evidences: [
        Necropsy::EdgeEvidence.new(
          caller_id: caller.id,
          callee_id: callee.id,
          evidence: evidence(analyzer: :coverage, kind: :call_edge)
        )
      ],
      observation: { 'coverage' => { 'environment' => 'production' } }
    )

    graph.apply_result(result)

    expect(graph).to be_dynamic_alive(caller.id)
    expect(graph).to be_dynamic_alive(callee.id)
  end

  it 'keeps every known endpoint alive and diagnoses partial observed edges' do
    full_caller = node('FullCaller#run')
    full_callee = node('FullCallee#run')
    known_caller = node('KnownCaller#run')
    known_callee = node('KnownCallee#run')
    unobserved = node('Unobserved#run')
    graph = graph_with(nodes: [full_caller, full_callee, known_caller, known_callee, unobserved])
    dynamic_evidence = evidence(analyzer: :coverage, kind: :call_edge)
    result = analyzer_result(
      edge_evidences: [
        edge_evidence(full_caller.id, full_callee.id, dynamic_evidence),
        edge_evidence(known_caller.id, 'MissingCallee#run', dynamic_evidence),
        edge_evidence('MissingCaller#run', known_callee.id, dynamic_evidence),
        edge_evidence('MissingBothCaller#run', 'MissingBothCallee#run', dynamic_evidence)
      ],
      observation: { 'coverage' => { 'environment' => 'production' } }
    )

    expect { graph.apply_result(result) }.to output(
      /fully matched 1 of 4 dynamic edges; partially matched 2; unmatched 1/
    ).to_stderr

    findings = Necropsy::Confidence::Scorer.new(
      graph: graph,
      reachability: Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}),
      project: project_for(create_project)
    ).findings
    expect(findings.map { |finding| finding.node.id }).to eq([unobserved.id])
    expect(graph.edges.map { |edge| [edge.caller_id, edge.callee_id] }).to eq([[full_caller.id, full_callee.id]])
    expect(graph.dynamic_evidence_diagnostic).to include(
      'attempted' => include('edges' => 4),
      'matched' => include('edges' => 1),
      'partially_matched' => include('edges' => 2),
      'unmatched' => include('edges' => 1),
      'unmatched_samples' => include(
        'edges' => [
          'KnownCaller#run -> MissingCallee#run (unmatched callee: MissingCallee#run)',
          'MissingBothCaller#run -> MissingBothCallee#run ' \
          '(unmatched caller: MissingBothCaller#run, callee: MissingBothCallee#run)',
          'MissingCaller#run -> KnownCallee#run (unmatched caller: MissingCaller#run)'
        ]
      )
    )
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

  it 'supports legacy reconciliation of broader standard static edges for the same call site' do
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

  it 'keys call sites by stable identity before the legacy field fallback' do
    graph = graph_with(nodes: [])
    first = call_site(caller_id: 'Caller#run', message: 'render')
    second = first.with(call_site_id: 'call:v1:second')
    first_payload = first.to_h
    second_payload = second.to_h

    expect(graph.send(:call_site_key, first_payload)).not_to eq(graph.send(:call_site_key, second_payload))
    expect(graph.send(:call_site_key, first_payload.except('call_site_id'))).to eq(
      graph.send(:call_site_key, second_payload.except('call_site_id'))
    )
  end

  it 'matches unknown dispatch blockers through the message index' do
    target = node('Target#call', owner: 'Target', name: 'call')
    graph = graph_with(nodes: [target])
    unrelated = 100.times.map do |index|
      unresolved_blocker(message: "other_#{index}")
    end
    matching = unresolved_blocker(message: 'call')
    graph.apply_result(analyzer_result(blockers: [*unrelated, matching]))
    allow(graph).to receive(:blocker_matches_node?).and_call_original

    expect(graph.matching_blockers(target)).to eq([matching])
    expect(graph).to have_received(:blocker_matches_node?).once
  end

  it 'deduplicates the same producer and call site with a constant-time key index' do
    target = node('Target#call', owner: 'Target', name: 'call')
    graph = graph_with(nodes: [target])
    first = unresolved_blocker(message: 'call')
    duplicate = first.with(metadata: first.metadata.merge('candidate_count' => 100))
    other_site = first.with(metadata: first.metadata.merge('line' => 9))

    [first, duplicate, other_site].each { |blocker| graph.add_blocker(blocker) }

    expect(graph.blockers).to eq([first, other_site])
    expect(graph.matching_blockers(target)).to eq([first, other_site])
  end

  it 'matches instance, constant, implicit, and unknown receiver scopes without crossing unrelated owners' do
    parent_instance = node('BaseParent#call', owner: 'BaseParent', name: 'call')
    child_instance = node('BaseChild#call', owner: 'BaseChild', name: 'call')
    private_child = node('PrivateChild#call', owner: 'PrivateChild', name: 'call', visibility: :private)
    parent_singleton = node('BaseParent.call', kind: :singleton_method, owner: 'BaseParent', name: 'call')
    unrelated = node('Other::Target#call', owner: 'Other::Target', name: 'call')
    graph = graph_with(
      nodes: [parent_instance, child_instance, private_child, parent_singleton, unrelated],
      class_infos: [
        class_info('BaseParent'),
        class_info('Base', superclass: 'BaseParent'),
        class_info('BaseChild', superclass: 'Base'),
        class_info('PrivateChild', superclass: 'Base'),
        class_info('Other::Target')
      ]
    )
    instance = unresolved_blocker(message: 'call', scope_kind: :owner, scope_value: ['Base'],
                                  receiver_kind: :instance)
    constant = unresolved_blocker(message: 'call', scope_kind: :owner, scope_value: ['Base'],
                                  receiver_kind: :constant)
    implicit = unresolved_blocker(message: 'call', scope_kind: :owner, scope_value: ['Base'],
                                  receiver_kind: :implicit)
    unknown = unresolved_blocker(message: 'call')

    graph.add_blocker(instance)
    expect(graph.matching_blockers(parent_instance)).to eq([instance])
    expect(graph.matching_blockers(child_instance)).to eq([instance])
    expect(graph.matching_blockers(private_child)).to eq([])
    expect(graph.matching_blockers(unrelated)).to eq([])

    graph = graph_with(nodes: graph.nodes.values, class_infos: graph.class_infos.values)
    graph.add_blocker(constant)
    expect(graph.matching_blockers(parent_singleton)).to eq([constant])
    expect(graph.matching_blockers(parent_instance)).to eq([])

    graph.add_blocker(implicit)
    expect(graph.matching_blockers(private_child)).to eq([implicit])
    expect(graph.matching_blockers(unrelated)).to eq([])

    graph.add_blocker(unknown)
    expect(graph.matching_blockers(parent_instance)).to include(unknown)
    expect(graph.matching_blockers(parent_singleton)).to include(unknown)
    expect(graph.matching_blockers(private_child)).not_to include(unknown)
  end

  it 'supports namespace scope and public-send visibility' do
    public_target = node('Billing::Handler#call', owner: 'Billing::Handler', name: 'call')
    protected_target = node('Billing::Fallback#call', owner: 'Billing::Fallback', name: 'call', visibility: :protected)
    private_target = node('Billing::Private#call', owner: 'Billing::Private', name: 'call', visibility: :private)
    other_target = node('Shipping::Handler#call', owner: 'Shipping::Handler', name: 'call')
    graph = graph_with(nodes: [public_target, protected_target, private_target, other_target])
    blocker = unresolved_blocker(
      message: 'call', scope_kind: :namespace, scope_value: 'Billing', receiver_kind: :unknown,
      original_message: 'public_send'
    )
    graph.add_blocker(blocker)

    expect(graph.matching_blockers(public_target)).to eq([blocker])
    expect(graph.matching_blockers(protected_target)).to eq([])
    expect(graph.matching_blockers(private_target)).to eq([])
    expect(graph.matching_blockers(other_target)).to eq([])
  end

  it 'matches private targets only for reflective APIs that can access them' do
    private_target = node('Target#call', owner: 'Target', name: 'call', visibility: :private)
    policies = {
      'send' => true,
      '__send__' => true,
      'method' => true,
      'public_send' => false,
      'respond_to?' => false,
      'regular_call' => false
    }

    policies.each do |original_message, expected|
      graph = graph_with(nodes: [private_target])
      graph.add_blocker(unresolved_blocker(message: 'call', original_message: original_message))

      expect(graph.matching_blockers(private_target).any?).to eq(expected), original_message
    end

    graph = graph_with(nodes: [private_target])
    graph.add_blocker(
      unresolved_blocker(message: 'call', original_message: 'respond_to?', include_private: true)
    )
    expect(graph.matching_blockers(private_target).any?).to eq(true)
  end

  it 'does not apply test-only unresolved dispatch to production definitions' do
    target = node('Target#call', owner: 'Target', name: 'call')
    graph = graph_with(nodes: [target])
    test_blocker = unresolved_blocker(message: 'call', domain: :test)
    runtime_blocker = unresolved_blocker(message: 'call', domain: :runtime)
    graph.apply_result(analyzer_result(blockers: [test_blocker, runtime_blocker]))

    expect(graph.matching_blockers(target)).to eq([runtime_blocker])
    expect(graph.matching_blockers(target, caller_domain: :test)).to eq([test_blocker])
  end

  it 'does not lose blocked definitions when an unknown scope broadens' do
    billing = node('Billing::Handler#call', owner: 'Billing::Handler', name: 'call')
    shipping = node('Shipping::Handler#call', owner: 'Shipping::Handler', name: 'call')
    nodes = [billing, shipping]
    scoped_graph = graph_with(nodes: nodes)
    scoped_graph.add_blocker(
      unresolved_blocker(message: 'call', scope_kind: :namespace, scope_value: 'Billing')
    )
    unknown_graph = graph_with(nodes: nodes)
    unknown_graph.add_blocker(unresolved_blocker(message: 'call'))

    scoped_matches = nodes.select { |candidate| scoped_graph.matching_blockers(candidate).any? }.to_set(&:id)
    unknown_matches = nodes.select { |candidate| unknown_graph.matching_blockers(candidate).any? }.to_set(&:id)

    expect(scoped_matches).to be_subset(unknown_matches)
  end
end

def edge_evidence(caller_id, callee_id, evidence)
  Necropsy::EdgeEvidence.new(caller_id: caller_id, callee_id: callee_id, evidence: evidence)
end
