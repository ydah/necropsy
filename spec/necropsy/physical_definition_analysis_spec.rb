# frozen_string_literal: true

RSpec.describe 'physical definition analysis' do
  def physical_node(symbol_id, definition_id, file:, line: 1, name: symbol_id.split(/[.#]/).last)
    node(
      symbol_id,
      symbol_id: symbol_id,
      definition_id: definition_id,
      body_digest: "digest-#{definition_id}",
      ordinal: 1,
      file: file,
      line: line,
      owner: symbol_id.split(/[.#]/).first,
      name: name
    )
  end

  it 'indexes physical nodes and expands logical entry points without choosing one definition' do
    first = physical_node('Repeated#run', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#run', 'def:v1:second', file: 'lib/second.rb')
    graph = graph_with(nodes: [second, first])

    graph.add_entry_point('Repeated#run', :public_api_declared)

    expect(graph.nodes).to be_a(Necropsy::DefinitionIndex)
    expect(graph.definitions_for('Repeated#run')).to eq([first, second])
    expect(graph.entry_points.map(&:node_id)).to eq([first.graph_id, second.graph_id])
    expect { graph.nodes['Repeated#run'] }.to raise_error(Necropsy::DefinitionIndex::AmbiguousDefinitionError)
  end

  it 'keeps exact physical entry points exact' do
    first = physical_node('Repeated#run', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#run', 'def:v1:second', file: 'lib/second.rb')
    graph = graph_with(nodes: [first, second])

    graph.add_entry_point(second.graph_id, :public_api_declared)

    expect(graph.entry_points.map(&:node_id)).to eq([second.graph_id])
  end

  it 'expands ambiguous logical edge and alive evidence to every physical definition and records it' do
    callers = [
      physical_node('Repeated#run', 'def:v1:caller-a', file: 'lib/a.rb'),
      physical_node('Repeated#run', 'def:v1:caller-b', file: 'lib/b.rb')
    ]
    callees = [
      physical_node('Repeated#target', 'def:v1:callee-a', file: 'lib/a.rb', line: 2),
      physical_node('Repeated#target', 'def:v1:callee-b', file: 'lib/b.rb', line: 2)
    ]
    graph = graph_with(nodes: callers + callees)

    expect(graph.add_edge('Repeated#run', 'Repeated#target', evidence)).to eq(true)
    expect(graph.add_alive('Repeated#target', evidence(kind: :alive))).to eq(true)

    expect(graph.edges.map { |edge| [edge.caller_id, edge.callee_id] }).to contain_exactly(
      *callers.product(callees).map { |caller, callee| [caller.graph_id, callee.graph_id] }
    )
    expect(callees).to all(satisfy { |callee| graph.dynamic_alive?(callee.graph_id) })
    expect(graph.observation.dig('definition_resolution', 'ambiguous_inputs')).to include(
      include('kind' => 'edge_caller', 'identifier' => 'Repeated#run'),
      include('kind' => 'edge_callee', 'identifier' => 'Repeated#target'),
      include('kind' => 'alive', 'identifier' => 'Repeated#target')
    )
  end

  it 'keeps exact physical edge and alive evidence exact' do
    caller = physical_node('Repeated#run', 'def:v1:caller', file: 'lib/caller.rb')
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb')
    graph = graph_with(nodes: [caller, first, second])

    graph.add_edge(caller.graph_id, first.graph_id, evidence)
    graph.add_alive(second.graph_id, evidence(kind: :alive))

    expect(graph.edges.map(&:callee_id)).to eq([first.graph_id])
    expect(graph).not_to be_dynamic_alive(first.graph_id)
    expect(graph).to be_dynamic_alive(second.graph_id)
    expect(graph.observation).not_to have_key('definition_resolution')
  end

  it 'keeps definition-scoped blockers physical' do
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb')
    graph = graph_with(nodes: [first, second])
    blocker = Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: :definition,
      scope_value: first.graph_id,
      source: :spec,
      reason: 'physical scope',
      metadata: { 'message' => 'target', 'caller_domain' => 'runtime' }
    )
    graph.add_blocker(blocker)

    expect(graph.matching_blockers(first)).to eq([blocker])
    expect(graph.matching_blockers(second)).to eq([])
  end

  it 'emits physical targets from every static analyzer' do
    caller = physical_node('Caller#run', 'def:v1:caller', file: 'lib/caller.rb')
    first = physical_node('Repeated#render', 'def:v1:first', file: 'lib/first.rb', name: 'render')
    second = physical_node('Repeated#render', 'def:v1:second', file: 'lib/second.rb', name: 'render')
    site = call_site(
      caller_id: caller.graph_id,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Repeated',
      metadata: { 'receiver_candidates' => ['Repeated'] }
    )
    graph = graph_with(
      nodes: [caller, first, second],
      call_sites: [site],
      instantiated_classes: Set['Repeated'],
      class_infos: [class_info('Caller'), class_info('Repeated')]
    )

    analyzers = [
      Necropsy::Analyzers::Static::NameResolution.new,
      Necropsy::Analyzers::Static::CHA.new,
      Necropsy::Analyzers::Static::RTA.new
    ]
    analyzers.each do |analyzer|
      targets = analyzer.analyze(graph, nil).edge_evidences.map(&:callee_id)
      expect(targets).to contain_exactly(first.graph_id, second.graph_id), analyzer.class.name
    end
  end

  it 'keeps duplicate reachability deterministic across insertion order' do
    caller = physical_node('Repeated#run', 'def:v1:caller', file: 'lib/caller.rb')
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb')
    forward = graph_with(nodes: [caller, first, second])
    reverse = graph_with(nodes: [second, first, caller])

    [forward, reverse].each do |graph|
      graph.add_entry_point(caller.graph_id, :main_script)
      graph.add_edge(caller.graph_id, 'Repeated#target', evidence)
    end

    expect(reverse.nodes.values).to eq(forward.nodes.values)
    expect(reverse.edges).to eq(forward.edges)
    expect(Necropsy::Reachability::Engine.new(reverse).call).to eq(
      Necropsy::Reachability::Engine.new(forward).call
    )
  end

  it 'keeps reopened definitions distinct through runner reachability and findings' do
    files = {
      'lib/root.rb' => "class Root\n  def run\n    Reopened.new.call\n  end\nend\n",
      'lib/first.rb' => "class Reopened\n  def call\n    first_target\n  end\n  def first_target; end\nend\n",
      'lib/second.rb' => "class Reopened\n  def call\n    second_target\n  end\n  def second_target; end\nend\n"
    }
    config = { cache: { enabled: false }, entry_points: { extra: ['Root#run'] } }

    with_project(files: files, config: config) do |root|
      report = Necropsy::Runner.new(root: root).analyze
      definitions = report.graph.definitions_for('Reopened#call')
      root_id = report.graph.definitions_for('Root#run').fetch(0).graph_id
      targets = report.graph.edges_from(root_id).keys

      expect(definitions.length).to eq(2)
      expect(targets).to include(*definitions.map(&:graph_id))
      expect(report.reachability.runtime_alive).to include(*definitions.map(&:graph_id))
      expect(report.findings.map(&:node)).not_to include(*definitions)
      expect(report.graph.edges).to all(
        satisfy { |edge| edge.caller_id.start_with?('def:v1:') && edge.callee_id.start_with?('def:v1:') }
      )
    end
  end
end
