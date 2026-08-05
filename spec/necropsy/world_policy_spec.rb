# frozen_string_literal: true

RSpec.describe Necropsy::WorldPolicy do
  it 'applies library world policy through the full runner pipeline' do
    source = <<~RUBY
      class PublishedLibrary
        def call; end

        private

        def internal_helper; end
      end
    RUBY

    with_project(
      files: { 'lib/published_library.rb' => source },
      config: { analysis: { world: :library }, analyzers: { static: [] }, cache: { enabled: false } }
    ) do |root|
      report = Necropsy::Runner.new(root: root).analyze
      external_symbols = report.graph.entry_points.select(&:external?).map do |entry|
        report.graph.nodes.fetch(entry.node_id).symbol_id
      end

      expect(external_symbols).to eq(['PublishedLibrary#call'])
      expect(report.findings.map { |finding| finding.node.symbol_id }).to eq(
        ['PublishedLibrary#internal_helper']
      )
      expect(report.findings.first).to have_attributes(classification: :unreachable, confidence: :medium)
    end
  end

  it 'protects library public and protected APIs while leaving private helpers eligible' do
    public_api = node('Library#call', owner: 'Library', name: 'call', file: 'lib/library.rb')
    protected_api = node(
      'Library#extension', owner: 'Library', name: 'extension', file: 'lib/library.rb', visibility: :protected
    )
    configured_hook = node(
      'Library#plugin_hook', owner: 'Library', name: 'plugin_hook', file: 'lib/library.rb', visibility: :private
    )
    private_helper = node(
      'Library#internal', owner: 'Library', name: 'internal', file: 'lib/library.rb', visibility: :private
    )
    test_api = node(
      'LibrarySpec#call', owner: 'LibrarySpec', name: 'call', file: 'spec/library_spec.rb', test: true
    )
    graph = graph_with(nodes: [public_api, protected_api, configured_hook, private_helper, test_api])

    with_project(
      files: { 'lib/library.rb' => '', 'spec/library_spec.rb' => '' },
      config: {
        analysis: { world: :library },
        entry_points: { extra: ['Library#plugin_hook'] }
      }
    ) do |root|
      project = project_for(root)
      Necropsy::EntryPoints::Plain.new.apply(graph, project)
      described_class.new(graph: graph, project: project).apply
      reachability = Necropsy::Reachability::Engine.new(graph).call
      findings = Necropsy::Confidence::Scorer.new(
        graph: graph, reachability: reachability, project: project
      ).findings

      expect(graph.entry_points.select(&:external?).map(&:node_id)).to contain_exactly(
        public_api.graph_id,
        protected_api.graph_id,
        configured_hook.graph_id
      )
      expect(reachability.external_alive).to contain_exactly(
        public_api.graph_id,
        protected_api.graph_id,
        configured_hook.graph_id
      )
      expect(reachability.runtime_alive).to eq([])
      expect(findings.map(&:node)).to eq([private_helper])
      expect(findings.first).to have_attributes(classification: :unreachable, confidence: :medium)
      expect(graph.matching_blockers(public_api).map(&:kind)).to eq([:open_public_api])
      expect(graph.matching_blockers(protected_api).map(&:kind)).to eq([:open_public_api])
      expect(graph.matching_blockers(private_helper)).to eq([])
    end
  end

  it 'keeps configured application hooks in the runtime domain' do
    hook = node('Application#hook', owner: 'Application', name: 'hook')
    graph = graph_with(nodes: [hook])

    with_project(config: { entry_points: { extra: ['Application#hook'] } }) do |root|
      project = project_for(root)
      Necropsy::EntryPoints::Plain.new.apply(graph, project)
      described_class.new(graph: graph, project: project).apply

      expect(graph.entry_points).to contain_exactly(
        have_attributes(node_id: hook.graph_id, domain: :runtime, reason: :public_api_declared)
      )
      expect(Necropsy::Reachability::Engine.new(graph).call.runtime_alive).to eq([hook.graph_id])
    end
  end

  it 'roots every non-test file top level only in all-file conservative mode' do
    production_root = node(
      'file:app/register.rb', kind: :block_entry, file: 'app/register.rb', owner: nil, name: 'app/register.rb'
    )
    registered = node('Registry#install', owner: 'Registry', name: 'install', file: 'app/register.rb')
    test_root = node(
      'file:spec/register_spec.rb', kind: :block_entry, file: 'spec/register_spec.rb', owner: nil,
                                    name: 'spec/register_spec.rb', test: true
    )
    graph = graph_with(nodes: [production_root, registered, test_root])
    graph.add_edge(production_root.graph_id, registered.graph_id, evidence)

    with_project(config: { analysis: { load_roots: :all } }) do |root|
      project = project_for(root)
      Necropsy::EntryPoints::Test.new.apply(graph, project)
      described_class.new(graph: graph, project: project).apply
      reachability = Necropsy::Reachability::Engine.new(graph).call

      expect(graph.entry_points).to include(
        have_attributes(
          node_id: production_root.graph_id, domain: :runtime, reason: :production_load_unit,
          evidence: include('type' => 'load_policy', 'policy' => 'all', 'file' => 'app/register.rb')
        ),
        have_attributes(node_id: test_root.graph_id, domain: :test, reason: :test_suite)
      )
      expect(reachability.runtime_alive).to contain_exactly(production_root.graph_id, registered.graph_id)
      expect(reachability.test_alive).to eq([test_root.graph_id])
      expect(reachability.runtime_alive).not_to include(test_root.graph_id)
    end
  end
end
