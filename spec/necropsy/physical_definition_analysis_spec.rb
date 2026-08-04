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

  it 'keeps ambiguous observed endpoints alive without inventing cartesian edges' do
    callers = [
      physical_node('Repeated#run', 'def:v1:caller-a', file: 'lib/a.rb'),
      physical_node('Repeated#run', 'def:v1:caller-b', file: 'lib/b.rb')
    ]
    callees = [
      physical_node('Repeated#target', 'def:v1:callee-a', file: 'lib/a.rb', line: 2),
      physical_node('Repeated#target', 'def:v1:callee-b', file: 'lib/b.rb', line: 2)
    ]
    graph = graph_with(nodes: callers + callees)
    observed = evidence(analyzer: :coverage, kind: :call_edge)
    result = analyzer_result(
      edge_evidences: [
        Necropsy::EdgeEvidence.new(
          caller_id: { 'symbol_id' => 'Repeated#run' },
          callee_id: { 'symbol_id' => 'Repeated#target' },
          evidence: observed
        )
      ],
      observation: { 'coverage' => { 'environment' => 'production' } }
    )

    expect { graph.apply_result(result) }.to output(/partially matched 1/).to_stderr

    expect(graph.edges).to be_empty
    expect(callers + callees).to all(satisfy { |definition| graph.dynamic_alive?(definition.graph_id) })
    expect(graph.dynamic_evidence_diagnostic).to include(
      'matched' => include('edges' => 0),
      'partially_matched' => include('edges' => 1),
      'resolution' => include(
        'edge_endpoints' => { 'exact' => 0, 'unique' => 0, 'ambiguous' => 2, 'missing' => 0 }
      )
    )
    expect(graph.observation.dig('definition_resolution', 'ambiguous_inputs')).to include(
      include('kind' => 'edge_caller', 'reference' => { 'symbol_id' => 'Repeated#run' }),
      include('kind' => 'edge_callee', 'reference' => { 'symbol_id' => 'Repeated#target' })
    )
  end

  it 'resolves structured runtime references exactly or by unique location hints' do
    caller = physical_node('Caller#run', 'def:v1:caller', file: 'lib/caller.rb', line: 3)
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb', line: 5)
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb', line: 7)
    fallback = physical_node('Fallback#run', 'def:v1:fallback', file: 'lib/fallback.rb', line: 9)
    graph = graph_with(nodes: [caller, first, second, fallback])
    observed = evidence(analyzer: :coverage, kind: :call_edge)
    result = analyzer_result(
      edge_evidences: [
        Necropsy::EdgeEvidence.new(
          caller_id: {
            'definition_id' => caller.graph_id, 'symbol_id' => caller.symbol_id,
            'file' => caller.file, 'line' => caller.line
          },
          callee_id: {
            'definition_id' => first.graph_id, 'symbol_id' => second.symbol_id,
            'file' => second.file, 'line' => second.line
          },
          evidence: observed
        )
      ],
      alive_evidences: [
        Necropsy::AliveEvidence.new(
          node_id: {
            definition_id: 'def:v1:stale', symbol_id: fallback.symbol_id,
            file: fallback.file, line: fallback.line
          },
          evidence: observed.with(kind: :alive)
        )
      ],
      observation: { 'coverage' => { 'environment' => 'production' } }
    )

    graph.apply_result(result)

    expect(graph.edges.map { |edge| [edge.caller_id, edge.callee_id] }).to eq(
      [[caller.graph_id, second.graph_id]]
    )
    expect(graph).not_to be_dynamic_alive(first.graph_id)
    expect(graph).to be_dynamic_alive(second.graph_id)
    expect(graph).to be_dynamic_alive(fallback.graph_id)
    expect(graph.dynamic_evidence_diagnostic.dig('resolution', 'nodes')).to eq(
      'exact' => 0, 'unique' => 1, 'ambiguous' => 0, 'missing' => 0
    )
    expect(graph.dynamic_evidence_diagnostic.dig('resolution', 'edge_endpoints')).to eq(
      'exact' => 1, 'unique' => 1, 'ambiguous' => 0, 'missing' => 0
    )
    expect(graph.dynamic_evidence_diagnostic.dig('resolution_samples', 'nodes')).to include(
      include(
        'reference' => {
          'definition_id' => 'def:v1:stale', 'symbol_id' => fallback.symbol_id,
          'file' => fallback.file, 'line' => fallback.line
        },
        'status' => 'unique', 'definition_ids' => [fallback.graph_id]
      )
    )
  end

  it 'does not use a stale physical ID fallback without an explicit location' do
    target = physical_node('Target#run', 'def:v1:target', file: 'lib/target.rb')
    graph = graph_with(nodes: [target])
    result = analyzer_result(
      alive_evidences: [
        Necropsy::AliveEvidence.new(
          node_id: { 'definition_id' => 'def:v1:stale', 'symbol_id' => target.symbol_id },
          evidence: evidence(analyzer: :coverage, kind: :alive)
        )
      ],
      observation: { 'coverage' => {} }
    )

    expect { graph.apply_result(result) }.to output(/missing 1/).to_stderr

    expect(graph).not_to be_dynamic_alive(target.graph_id)
    expect(graph.dynamic_evidence_diagnostic.dig('resolution', 'nodes', 'missing')).to eq(1)
  end

  it 'keeps resolution counts additive and samples bounded across input order' do
    references = 7.times.map do |index|
      {
        'definition_id' => "def:v1:missing-#{index}",
        'symbol_id' => "Missing#{index}#run",
        'file' => "lib/missing_#{index}.rb",
        'line' => index + 1
      }
    end
    diagnostics = [references, references.reverse].map do |ordered|
      graph = graph_with(nodes: [physical_node('Known#run', 'def:v1:known', file: 'lib/known.rb')])
      result = analyzer_result(
        alive_evidences: ordered.map do |reference|
          Necropsy::AliveEvidence.new(
            node_id: reference,
            evidence: evidence(analyzer: :coverage, kind: :alive)
          )
        end,
        observation: { 'coverage' => {} }
      )
      expect { graph.apply_result(result) }.to output(/missing 7/).to_stderr
      graph.dynamic_evidence_diagnostic
    end

    expect(diagnostics.last.dig('resolution_samples', 'nodes')).to eq(
      diagnostics.first.dig('resolution_samples', 'nodes')
    )
    expect(diagnostics.first.dig('resolution_samples', 'nodes').length).to eq(5)
    diagnostics.each do |diagnostic|
      expect(diagnostic.dig('resolution', 'nodes').values.sum).to eq(diagnostic.dig('attempted', 'nodes'))
      expect(
        diagnostic.dig('matched', 'nodes') + diagnostic.dig('partially_matched', 'nodes') +
        diagnostic.dig('unmatched', 'nodes')
      ).to eq(diagnostic.dig('attempted', 'nodes'))
    end
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

    expect(graph.matching_blockers(first)).to include(blocker)
    expect(graph.matching_blockers(second)).not_to include(blocker)
  end

  it 'blocks every production duplicate but does not leak test-only duplicates into production' do
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb').with(visibility: :private)
    test_first = physical_node('TestOnly#target', 'def:v1:test-first', file: 'spec/first_spec.rb').with(test: true)
    test_second = physical_node('TestOnly#target', 'def:v1:test-second', file: 'spec/second_spec.rb').with(test: true)
    graph = graph_with(nodes: [first, second, test_first, test_second])
    blocker = graph.blockers.find { |item| item.kind == :duplicate_definition }

    expect(blocker).to have_attributes(scope_kind: :symbol, scope_value: 'Repeated#target')
    expect(blocker.metadata).to include(
      'definition_count' => 2,
      'definition_ids' => %w[def:v1:first def:v1:second],
      'locations' => [
        { 'definition_id' => first.graph_id, 'file' => first.file, 'line' => first.line },
        { 'definition_id' => second.graph_id, 'file' => second.file, 'line' => second.line }
      ]
    )
    expect(graph.matching_blockers(first)).to include(blocker)
    expect(graph.matching_blockers(second)).to include(blocker)
    expect(graph.matching_blockers(test_first)).to be_empty
    expect(graph.matching_blockers(test_second)).to be_empty
  end

  it 'refreshes duplicate blocker metadata when a definition is added later' do
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb')
    third = physical_node('Repeated#target', 'def:v1:third', file: 'lib/third.rb')
    graph = graph_with(nodes: [first, second])

    graph.add_node(third)

    blockers = graph.blockers.select { |item| item.kind == :duplicate_definition }
    expect(blockers.length).to eq(1)
    expect(blockers.first.metadata).to include(
      'definition_count' => 3,
      'definition_ids' => %w[def:v1:first def:v1:second def:v1:third]
    )
    expect(graph.matching_blockers(third)).to eq(blockers)
  end

  it 'keeps an unobserved production duplicate blocked after exact physical evidence' do
    first = physical_node('Repeated#target', 'def:v1:first', file: 'lib/first.rb')
    second = physical_node('Repeated#target', 'def:v1:second', file: 'lib/second.rb')
    graph = graph_with(nodes: [first, second])
    graph.apply_result(analyzer_result(
                         alive_evidences: [
                           Necropsy::AliveEvidence.new(
                             node_id: first.graph_id,
                             evidence: evidence(analyzer: :coverage, kind: :alive)
                           )
                         ],
                         observation: { 'coverage' => {} }
                       ))
    findings = Necropsy::Confidence::Scorer.new(
      graph: graph,
      reachability: Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}),
      project: project_for(create_project)
    ).findings

    expect(findings.map(&:node)).to eq([second])
    expect(findings.first).to have_attributes(
      classification: :blocked,
      blockers: include(have_attributes(kind: :duplicate_definition, scope_value: second.symbol_id))
    )
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
