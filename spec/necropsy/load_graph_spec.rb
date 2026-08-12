# frozen_string_literal: true

RSpec.describe Necropsy::LoadGraph do
  def root_for(graph, file)
    graph.nodes.values.find { |node| node.kind == :block_entry && node.file == file }
  end

  it 'links literal relative, lib-path, and autoload references to stable file roots' do
    files = {
      'bin/tool' => "#!/usr/bin/env ruby\nrequire_relative '../lib/direct'\n",
      'lib/direct.rb' => "DIRECT = true\n",
      'lib/package/required.rb' => "REQUIRED = true\n",
      'lib/package/lazy.rb' => "LAZY = true\n",
      'lib/package/loader.rb' => "require 'package/required'\nautoload :Lazy, 'package/lazy'\n"
    }

    with_project(files: files, config: { cache: { enabled: false } }) do |root|
      project = project_for(root)
      graph = Necropsy::CallGraph.new(project.scan_result)

      described_class.new(graph: graph, project: project).apply

      expect(graph).to be_edge_present(root_for(graph, 'bin/tool').graph_id, root_for(graph, 'lib/direct.rb').graph_id)
      loader = root_for(graph, 'lib/package/loader.rb')
      expect(graph).to be_edge_present(loader.graph_id, root_for(graph, 'lib/package/required.rb').graph_id)
      expect(graph).to be_edge_present(loader.graph_id, root_for(graph, 'lib/package/lazy.rb').graph_id)
      expect(graph.observation.fetch('load_graph')).to include(
        'resolved_count' => 3,
        'unresolved_literal_count' => 0,
        'dynamic_count' => 0
      )

      graph.add_entry_point(root_for(graph, 'bin/tool').graph_id, :main_script, domain: :runtime)
      reachability = Necropsy::Reachability::Engine.new(graph).call
      described_class.record_unrooted_units(graph: graph, reachability: reachability)
      expect(graph.observation.dig('unrooted_load_units', 'units')).to include(
        include('file' => 'lib/package/loader.rb', 'top_level_calls' => contain_exactly('autoload', 'require'))
      )
      expect(graph.observation.dig('unrooted_load_units', 'units')).not_to include(include('file' => 'bin/tool'))
    end
  end

  it 'makes dynamic loads conservative only after their caller is reached and records a scoped blocker' do
    files = {
      'lib/loader.rb' => "class Loader\n  def run(path)\n    require path\n  end\nend\n",
      'lib/possible.rb' => "POSSIBLE = true\n",
      'spec/helper.rb' => "TEST_ONLY = true\n"
    }

    with_project(files: files, config: { cache: { enabled: false } }) do |root|
      project = project_for(root)
      graph = Necropsy::CallGraph.new(project.scan_result)
      caller = graph.definitions_for('Loader#run').fetch(0)

      described_class.new(graph: graph, project: project).apply

      expect(graph).to be_edge_present(caller.graph_id, root_for(graph, 'lib/possible.rb').graph_id)
      expect(graph).not_to be_edge_present(caller.graph_id, root_for(graph, 'spec/helper.rb').graph_id)
      expect(graph.blockers).to include(
        have_attributes(kind: :dynamic_load, scope_kind: :definition, scope_value: caller.graph_id)
      )
      expect(graph.observation.dig('load_graph', 'dynamic_count')).to eq(1)
    end
  end

  it 'does not classify arbitrary receiver methods as Ruby load primitives' do
    with_project(
      files: { 'lib/not_a_load.rb' => "loader.require 'package/target'\n" },
      config: { cache: { enabled: false } }
    ) do |root|
      scan = project_for(root).scan_result

      expect(scan.call_sites.find { |site| site.message == 'require' }.metadata).not_to have_key('load_reference')
    end
  end
end
