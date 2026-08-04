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
    expect(payload.dig('path', 1, 'edge')).to include(
      'caller' => include('symbol_id' => root_node.symbol_id, 'definition_id' => root_node.definition_id),
      'callee' => include('symbol_id' => alive.symbol_id, 'definition_id' => alive.definition_id)
    )
    expect(diagnostics.render(payload)).to include('Alive (runtime)', 'via name_resolution', 'exe/tool:3')
  end

  it 'explains a dead node with nearby alive nodes and uncertainty' do
    payload = diagnostics.why(dead.id)

    expect(payload).to include('status' => 'dead', 'classification' => 'unreachable')
    expect(payload.fetch('nearest_alive')).to include('node_id' => alive.id, 'distance' => 1)
    expect(payload.dig('nearest_alive', 'node')).to include(
      'symbol_id' => alive.symbol_id, 'definition_id' => alive.definition_id
    )
    expect(payload.fetch('uncertainties')).to include('Dynamic dispatch nearby')
  end

  it 'returns every physical definition and executable commands for an ambiguous symbol' do
    first = node(
      'Repeated#run', symbol_id: 'Repeated#run', definition_id: 'def:v1:first', file: 'lib/first.rb', line: 3
    )
    second = node(
      'Repeated#run', symbol_id: 'Repeated#run', definition_id: 'def:v1:second', file: 'lib/second.rb', line: 7
    )
    ambiguous_graph = graph_with(nodes: [second, first])
    ambiguous_report = Necropsy::Report.new(
      root: '/repo', graph: ambiguous_graph, findings: [],
      reachability: Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {})
    )
    ambiguous_diagnostics = described_class.new(ambiguous_report)

    payload = ambiguous_diagnostics.why('Repeated#run')

    expect(payload).to include('status' => 'ambiguous', 'node_id' => 'Repeated#run')
    expected_definitions = [
      {
        'symbol_id' => 'Repeated#run', 'definition_id' => 'def:v1:first', 'file' => 'lib/first.rb', 'line' => 3,
        'commands' => {
          'why' => 'bundle exec necropsy why def:v1:first --root /repo',
          'explain' => 'bundle exec necropsy explain def:v1:first --root /repo'
        }
      },
      {
        'symbol_id' => 'Repeated#run', 'definition_id' => 'def:v1:second', 'file' => 'lib/second.rb', 'line' => 7,
        'commands' => {
          'why' => 'bundle exec necropsy why def:v1:second --root /repo',
          'explain' => 'bundle exec necropsy explain def:v1:second --root /repo'
        }
      }
    ]
    expect(payload.fetch('definitions')).to eq(expected_definitions)
    expect(ambiguous_diagnostics.explain('Repeated#run')).to eq(payload)
    expect(ambiguous_diagnostics.why('def:v1:first')).to include('status' => 'dead')
    expect(JSON.parse(ambiguous_diagnostics.render(payload, format: :json))).to eq(payload)
    expect(ambiguous_diagnostics.render(payload)).to include(
      'Ambiguous symbol ID: Repeated#run',
      'Repeated#run [def:v1:first] lib/first.rb:3',
      'why: bundle exec necropsy why def:v1:first --root /repo'
    )
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

  context 'with a blocker matching a test-reachable definition' do
    let(:blocker) do
      Necropsy::Blocker.new(
        kind: :unknown_dispatch,
        scope_kind: :owner,
        scope_value: ['Sample'],
        source: :name_resolution,
        reason: 'Dispatch call has 5 candidates, exceeding the configured ambiguity limit',
        suggested_action: :review_receiver_flow,
        metadata: {
          'caller_id' => 'Sample::Router#route', 'caller_domain' => 'runtime', 'message' => 'call',
          'receiver_kind' => 'instance', 'file' => 'app/router.rb', 'line' => 31, 'candidate_count' => 5
        }
      )
    end
    let(:blocked_node) { node('Sample#call', owner: 'Sample', name: 'call') }
    let(:graph) do
      graph_with(nodes: [blocked_node], class_infos: [class_info('Sample')]).tap do |result|
        result.add_blocker(blocker)
      end
    end
    let(:reachability) do
      Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: { blocked_node.id => nil })
    end
    let(:blocked_finding) do
      finding(id: blocked_node.id, classification: :blocked, confidence: :low, score: 0.25, blockers: [blocker])
    end
    let(:report) do
      Necropsy::Report.new(root: '/repo', graph: graph, findings: [blocked_finding], reachability: reachability)
    end

    it 'shows call site, scope, and reason in why and explain output' do
      why_payload = diagnostics.why(blocked_node.id)
      explain_payload = diagnostics.explain(blocked_node.id)

      expect(why_payload).to include('status' => 'blocked', 'classification' => 'blocked')
      expect(why_payload.dig('blockers', 0)).to include(
        'scope_kind' => 'owner', 'reason' => match(/exceeding the configured ambiguity limit/)
      )
      expect(diagnostics.render(why_payload)).to include(
        'Blocked: Sample#call',
        'Blocker: unknown_dispatch at app/router.rb:31 caller=Sample::Router#route',
        'Scope: owner=["Sample"] message=call',
        'Reason: Dispatch call has 5 candidates'
      )
      expect(explain_payload.fetch('blockers')).to eq(why_payload.fetch('blockers'))
      expect(JSON.parse(diagnostics.render(explain_payload, format: :json)).dig('blockers', 0, 'metadata')).to include(
        'file' => 'app/router.rb', 'line' => 31
      )
    end
  end
end
