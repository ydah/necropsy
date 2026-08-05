# frozen_string_literal: true

RSpec.describe Necropsy::Reachability::Engine do
  it 'keeps legacy two-argument reachability results compatible' do
    result = Necropsy::Reachability::Result.new({ 'Runtime#root' => nil }, { 'Spec#root' => nil })

    expect(result.runtime_alive).to eq(['Runtime#root'])
    expect(result.test_alive).to eq(['Spec#root'])
    expect(result.external_alive).to eq([])
  end

  it 'traverses runtime, test, and external entry-point graphs separately' do
    runtime = node('Runtime#root', owner: 'Runtime', name: 'root')
    runtime_child = node('Runtime#child', owner: 'Runtime', name: 'child')
    test_root = node('Spec#root', owner: 'Spec', name: 'root', test: true)
    test_child = node('Spec#child', owner: 'Spec', name: 'child')
    external_root = node('Library#root', owner: 'Library', name: 'root')
    external_child = node('Library#child', owner: 'Library', name: 'child')
    graph = graph_with(nodes: [runtime, runtime_child, test_root, test_child, external_root, external_child])
    graph.add_entry_point(runtime.id, :main_script)
    graph.add_entry_point(test_root.id, :test_suite, domain: :test)
    graph.add_entry_point(external_root.id, :library_public_api, domain: :external)
    graph.add_edge(runtime.id, runtime_child.id, evidence)
    graph.add_edge(test_root.id, test_child.id, evidence)
    graph.add_edge(external_root.id, external_child.id, evidence)

    result = described_class.new(graph).call

    expect(result.runtime_alive).to contain_exactly(runtime.id, runtime_child.id)
    expect(result.test_alive).to contain_exactly(test_root.id, test_child.id)
    expect(result.external_alive).to contain_exactly(external_root.id, external_child.id)
    expect(result.runtime_alive).not_to include(test_root.id, external_root.id)
    expect(result.witness(runtime_child.id)).to eq([runtime.id, runtime_child.id])
    expect(result.witness(test_child.id, kind: :test)).to eq([test_root.id, test_child.id])
    expect(result.witness(external_child.id, kind: :external)).to eq([external_root.id, external_child.id])
    expect(result.witness('Missing#node')).to be_nil
    expect { result.witness(runtime.id, kind: :unknown) }.to raise_error(ArgumentError, /kind/)
  end

  it 'does not let test definitions bridge runtime or external reachability' do
    runtime_root = node('Runtime#root', owner: 'Runtime', name: 'root')
    external_root = node('Library#root', owner: 'Library', name: 'root')
    test_bridge = node('Spec#bridge', owner: 'Spec', name: 'bridge', test: true)
    production_target = node('Production#target', owner: 'Production', name: 'target')
    graph = graph_with(nodes: [runtime_root, external_root, test_bridge, production_target])
    graph.add_entry_point(runtime_root.id, :main_script, domain: :runtime)
    graph.add_entry_point(external_root.id, :library_public_api, domain: :external)
    graph.add_entry_point(test_bridge.id, :test_suite, domain: :test)
    graph.add_edge(runtime_root.id, test_bridge.id, evidence)
    graph.add_edge(external_root.id, test_bridge.id, evidence)
    graph.add_edge(test_bridge.id, production_target.id, evidence)

    result = described_class.new(graph).call

    expect(result.runtime_alive).to eq([runtime_root.id])
    expect(result.external_alive).to eq([external_root.id])
    expect(result.test_alive).to contain_exactly(test_bridge.id, production_target.id)
  end
end
