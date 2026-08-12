# frozen_string_literal: true

RSpec.describe Necropsy::Report do
  it 'filters dead methods by confidence and summarizes classifications' do
    high = finding(id: 'Sample#dead', classification: :unreachable, confidence: :high)
    low = finding(id: 'Sample#maybe', classification: :unused, confidence: :low)
    test_only = finding(id: 'Sample#test_only', classification: :test_only_reachable, confidence: :medium)
    graph = graph_with(nodes: [high.node, low.node, test_only.node])
    report = described_class.new(root: '/repo', graph: graph, findings: [high, low, test_only])

    expect(report.dead_methods(min_confidence: :medium).map(&:node)).to contain_exactly(high.node, test_only.node)
    expect(report.finding_for_definition(high.node.graph_id)).to eq(high)
    expect(report.finding_for_definition('missing')).to be_nil
    expect(report.actionable_candidates(min_confidence: :medium).map(&:node)).to contain_exactly(high.node)
    expect(report.diagnostic_findings.map(&:node)).to contain_exactly(test_only.node)
    expect(report.summary).to include(
      'nodes' => 3,
      'edges' => 0,
      'entry_points' => 0,
      'findings' => 3,
      'unreachable' => 1,
      'unused' => 1,
      'test_only_reachable' => 1
    )
    expect(report.to_h).to include(
      'schema_version' => 2,
      'root' => '/repo',
      'findings' => include(include('classification' => 'unreachable'))
    )
    expect(report.to_h.dig('compatibility', 'finding_fingerprints')).to include(
      'fingerprint' => match(/legacy logical/),
      'physical_fingerprint' => match(/physical definition/)
    )
    expect(report.to_h.fetch('artifact_provenance')).to eq(
      'producer' => { 'name' => 'necropsy', 'version' => Necropsy::VERSION },
      'runtime' => {
        'ruby_engine' => RUBY_ENGINE,
        'ruby_version' => RUBY_VERSION,
        'prism_version' => Prism::VERSION
      },
      'identity_schemas' => { 'definition' => 1, 'call_site' => 1 },
      'inputs' => { 'configuration_sha256' => 'unavailable' }
    )
    expect(report.to_h).not_to have_key('graph')
    expect(report.to_h(include_graph: true)).to include('graph' => include('nodes'))
    expect(JSON.parse(JSON.generate('report' => report))).to include('report' => include('root' => '/repo'))
  end

  it 'filters report output by path without removing graph nodes' do
    included = finding(id: 'Included#dead', file: 'lib/included.rb')
    excluded = finding(id: 'Excluded#dead', file: 'app/excluded.rb')
    ignored = finding(id: 'Ignored#dead', file: 'lib/generated/ignored.rb')
    graph = graph_with(nodes: [included.node, excluded.node, ignored.node])
    report = described_class.new(
      root: '/repo',
      graph: graph,
      findings: [included, excluded, ignored],
      report_include_paths: ['lib/**'],
      report_exclude_paths: ['lib/generated/**']
    )

    expect(report.graph.nodes.length).to eq(3)
    expect(report.dead_methods.map(&:node)).to eq([included.node])
    expect(report.reportable_findings.map(&:node)).to eq([included.node])
    expect(report.summary['findings']).to eq(1)
    expect(report.to_h['findings'].map { |finding| finding.dig('node', 'id') }).to eq([included.node.id])
  end

  it 'serializes findings deterministically regardless of insertion order' do
    later = finding(id: 'Later#dead', file: 'lib/z_later.rb', line: 3)
    earlier = finding(id: 'Earlier#dead', file: 'lib/a_earlier.rb', line: 9)
    graph = graph_with(nodes: [later.node, earlier.node])

    forward = described_class.new(root: '/repo', graph: graph, findings: [later, earlier])
    reverse = described_class.new(root: '/repo', graph: graph, findings: [earlier, later])

    expect(forward.findings.map { |item| item.node.id }).to eq(%w[Earlier#dead Later#dead])
    expect(forward.to_json).to eq(reverse.to_json)
  end

  it 'uses physical definition IDs to deterministically order otherwise identical findings' do
    base = finding(id: 'Repeated#dead', file: 'lib/repeated.rb', line: 3)
    second = base.with(node: base.node.with(definition_id: 'def:v1:second'))
    first = base.with(node: base.node.with(definition_id: 'def:v1:first'))
    graph = graph_with(nodes: [second.node, first.node])

    report = described_class.new(root: '/repo', graph: graph, findings: [second, first])

    expect(report.findings.map { |item| item.node.definition_id }).to eq(%w[def:v1:first def:v1:second])
  end

  it 'exposes definition-resolution observations without requiring the full graph' do
    first = node('Repeated#run', definition_id: 'def:v1:first')
    second = node('Repeated#run', definition_id: 'def:v1:second')
    graph = graph_with(nodes: [first, second])
    graph.add_alive('Repeated#run', evidence(kind: :alive))
    report = described_class.new(root: '/repo', graph: graph, findings: [])

    expect(report.to_h).not_to have_key('graph')
    resolution = report.to_h.dig('diagnostics', 'definition_resolution')
    expect(resolution.fetch('ambiguous_input_count')).to eq(1)
    expect(resolution.fetch('ambiguous_inputs')).to include(
      include(
        'kind' => 'alive', 'identifier' => 'Repeated#run',
        'definition_ids' => %w[def:v1:first def:v1:second]
      )
    )
  end
end
