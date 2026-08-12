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

  it 'does not derive public API roots from gemspecs outside the reference scope' do
    public_api = node(
      'ExampleGem.analyze',
      kind: :singleton_method,
      file: 'lib/example_gem.rb',
      owner: 'ExampleGem',
      name: 'analyze'
    )
    graph = graph_with(nodes: [public_api])

    with_project(
      files: {
        'example_gem.gemspec' => "Gem::Specification.new { |spec| spec.name = 'example_gem' }\n",
        'lib/example_gem.rb' => "module ExampleGem; end\n"
      },
      config: { paths: { reference: ['lib/**'] } }
    ) do |root|
      described_class.new.apply(graph, project_for(root))
    end

    expect(graph.entry_points).to eq([])
  end

  it 'reads the primary require file structurally from the Gem specification block' do
    public_api = node(
      'Company::Gem.analyze',
      kind: :singleton_method,
      file: 'src/company/gem.rb',
      owner: 'Company::Gem',
      name: 'analyze'
    )
    decoy = node(
      'Decoy.analyze', kind: :singleton_method, file: 'lib/decoy.rb', owner: 'Decoy', name: 'analyze'
    )
    graph = graph_with(nodes: [public_api, decoy])

    with_project(
      files: {
        'company.gemspec' => <<~RUBY,
          NOTICE = "spec.name = 'decoy'"
          Gem::Specification.new do |package|
            package.name = 'company-gem'
            package.require_paths = ['src']
          end
        RUBY
        'src/company/gem.rb' => "module Company::Gem; end\n",
        'lib/decoy.rb' => "module Decoy; end\n"
      }
    ) do |root|
      described_class.new.apply(graph, project_for(root))
    end

    expect(graph.entry_points.map(&:node_id)).to include(public_api.graph_id)
    expect(graph.entry_points.map(&:node_id)).not_to include(decoy.graph_id)
  end

  it 'does not read gemspec symlinks that resolve outside the repository' do
    Dir.mktmpdir do |outside|
      gemspec = File.join(outside, 'external.gemspec')
      File.write(gemspec, "Gem::Specification.new { |spec| spec.name = 'example_gem' }\n")
      root = create_project(files: { 'lib/example_gem.rb' => "module ExampleGem; end\n" })
      File.symlink(gemspec, File.join(root, 'example_gem.gemspec'))
      graph = graph_with(
        nodes: [
          node('ExampleGem.analyze', kind: :singleton_method, file: 'lib/example_gem.rb',
                                     owner: 'ExampleGem', name: 'analyze')
        ]
      )

      described_class.new.apply(graph, project_for(root))

      expect(graph.entry_points).to eq([])
    end
  end
end
