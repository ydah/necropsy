# frozen_string_literal: true

RSpec.describe Necropsy::EntryPoints::Plain do
  it 'adds script, configured public API, and top-level Necropsy API entry points' do
    nodes = [
      node('file:bin/tool', kind: :block_entry, file: 'bin/tool', owner: nil, name: 'bin/tool'),
      node('Company::Public#call', owner: 'Company::Public', name: 'call'),
      node('Necropsy.analyze', kind: :singleton_method, file: 'lib/necropsy.rb', owner: 'Necropsy', name: 'analyze'),
      node('file:spec/tool_spec.rb', kind: :block_entry, file: 'spec/tool_spec.rb', owner: nil, name: 'spec/tool_spec.rb',
                                test: true)
    ]
    graph = graph_with(nodes: nodes)

    with_project(config: { entry_points: { extra: ['Company::Public#*'] } }) do |root|
      described_class.new.apply(graph, project_for(root))
    end

    expect(graph.entry_points.map { |entry| [entry.node_id, entry.reason] }).to contain_exactly(
      ['file:bin/tool', :main_script],
      ['Company::Public#call', :public_api_declared],
      ['Necropsy.analyze', :public_api_declared]
    )
  end
end
