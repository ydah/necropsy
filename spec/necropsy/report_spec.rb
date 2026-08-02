# frozen_string_literal: true

RSpec.describe Necropsy::Report do
  it 'filters dead methods by confidence and summarizes classifications' do
    high = finding(id: 'Sample#dead', classification: :unreachable, confidence: :high)
    low = finding(id: 'Sample#maybe', classification: :unused, confidence: :low)
    test_only = finding(id: 'Sample#test_only', classification: :test_only_reachable, confidence: :medium)
    graph = graph_with(nodes: [high.node, low.node, test_only.node])
    report = described_class.new(root: '/repo', graph: graph, findings: [high, low, test_only])

    expect(report.dead_methods(min_confidence: :medium).map(&:node)).to contain_exactly(high.node, test_only.node)
    expect(report.summary).to include(
      'nodes' => 3,
      'edges' => 0,
      'entry_points' => 0,
      'findings' => 3,
      'unreachable' => 1,
      'unused' => 1,
      'test_only_reachable' => 1
    )
    expect(report.to_h).to include('root' => '/repo', 'findings' => include(include('classification' => 'unreachable')))
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
    expect(report.summary['findings']).to eq(1)
    expect(report.to_h['findings'].map { |finding| finding.dig('node', 'id') }).to eq([included.node.id])
  end
end
