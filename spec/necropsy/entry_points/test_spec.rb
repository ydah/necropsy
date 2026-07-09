# frozen_string_literal: true

RSpec.describe Necropsy::EntryPoints::Test do
  it 'adds test block entries as test-suite roots' do
    graph = graph_with(nodes: [
      node('file:spec/widget_spec.rb', kind: :block_entry, file: 'spec/widget_spec.rb', owner: nil,
                                  name: 'spec/widget_spec.rb', test: true),
      node('file:app/widget.rb', kind: :block_entry, file: 'app/widget.rb', owner: nil, name: 'app/widget.rb')
    ])

    described_class.new.apply(graph, nil)

    expect(graph.entry_points).to contain_exactly(
      Necropsy::EntryPoint.new(node_id: 'file:spec/widget_spec.rb', reason: :test_suite)
    )
  end
end
