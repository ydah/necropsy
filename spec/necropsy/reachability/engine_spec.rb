# frozen_string_literal: true

RSpec.describe Necropsy::Reachability::Engine do
  it 'traverses runtime and test entry-point graphs separately' do
    runtime = node('Runtime#root', owner: 'Runtime', name: 'root')
    runtime_child = node('Runtime#child', owner: 'Runtime', name: 'child')
    test_root = node('Spec#root', owner: 'Spec', name: 'root', test: true)
    test_child = node('Spec#child', owner: 'Spec', name: 'child')
    graph = graph_with(nodes: [runtime, runtime_child, test_root, test_child])
    graph.add_entry_point(runtime.id, :main_script)
    graph.add_entry_point(test_root.id, :test_suite)
    graph.add_edge(runtime.id, runtime_child.id, evidence)
    graph.add_edge(test_root.id, test_child.id, evidence)

    result = described_class.new(graph).call

    expect(result.runtime_alive).to eq(Set[runtime.id, runtime_child.id])
    expect(result.test_alive).to eq(Set[test_root.id, test_child.id])
  end
end
