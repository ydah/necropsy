# frozen_string_literal: true

RSpec.describe Necropsy::EntryPoints::Plain do
  it 'adds scripts, configured APIs, and public APIs derived from the target gem entry file' do
    nodes = [
      node('file:bin/tool', kind: :block_entry, file: 'bin/tool', owner: nil, name: 'bin/tool'),
      node('Company::Public#call', owner: 'Company::Public', name: 'call'),
      node('ExampleGem.analyze', kind: :singleton_method, file: 'lib/example_gem.rb', owner: 'ExampleGem',
                                 name: 'analyze'),
      node('ExampleGem.internal', kind: :singleton_method, file: 'lib/example_gem.rb', owner: 'ExampleGem',
                                  name: 'internal', visibility: :private),
      node('file:spec/tool_spec.rb', kind: :block_entry, file: 'spec/tool_spec.rb', owner: nil, name: 'spec/tool_spec.rb',
                                     test: true)
    ]
    graph = graph_with(nodes: nodes)

    with_project(
      files: {
        'example_gem.gemspec' => "Gem::Specification.new { |spec| spec.name = 'example_gem' }\n",
        'lib/example_gem.rb' => "module ExampleGem; end\n"
      },
      config: { entry_points: { extra: ['Company::Public#*'] } }
    ) do |root|
      described_class.new.apply(graph, project_for(root))
    end

    expect(graph.entry_points.map { |entry| [entry.node_id, entry.reason] }).to contain_exactly(
      ['file:bin/tool', :main_script],
      ['Company::Public#call', :public_api_declared],
      ['ExampleGem.analyze', :public_api_declared]
    )
  end
end
