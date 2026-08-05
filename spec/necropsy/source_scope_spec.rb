# frozen_string_literal: true

RSpec.describe 'analysis, reference, and report source scopes' do
  it 'keeps reference-only Ruby callers in the graph without reporting their definitions' do
    target_source = <<~RUBY
      class ScopeTarget
        def from_executable; end
        def from_test; end
        def from_initializer; end
        def unreferenced; end
      end
    RUBY
    executable_source = <<~RUBY
      #!/usr/bin/env ruby
      ScopeTarget.new.from_executable

      class ReferenceOnlyExecutable
        def unused_helper; end
      end
    RUBY
    test_source = 'ScopeTarget.new.from_test'
    initializer_source = 'ScopeTarget.new.from_initializer'
    files = {
      'lib/scope_target.rb' => target_source,
      'exe/scope_tool' => executable_source,
      'spec/scope_target_spec.rb' => test_source,
      'config/initializers/scope_target.rb' => initializer_source,
      'config/schedule.yml' => "nightly: ScopeTarget#from_executable\n"
    }
    config = {
      cache: { enabled: false },
      frameworks: ['rails'],
      paths: { analyze: ['lib/**'], reference: ['**/*'] }
    }

    with_project(files: files, config: config) do |root|
      report = Necropsy::Runner.new(root: root).analyze
      graph = report.graph
      findings = report.findings.to_h { |finding| [finding.node.symbol_id, finding] }

      expect(graph.source_domains).to include(
        'lib/scope_target.rb' => :analyze,
        'exe/scope_tool' => :reference,
        'spec/scope_target_spec.rb' => :reference,
        'config/initializers/scope_target.rb' => :reference
      )
      expect(graph.nodes.values.map(&:symbol_id)).to include('ReferenceOnlyExecutable#unused_helper')
      expect(findings).not_to have_key('ReferenceOnlyExecutable#unused_helper')
      expect(findings).not_to have_key('ScopeTarget#from_executable')
      expect(findings).not_to have_key('ScopeTarget#from_initializer')
      expect(findings.fetch('ScopeTarget#from_test')).to have_attributes(
        classification: :test_only_reachable
      )
      expect(findings.fetch('ScopeTarget#unreferenced')).to have_attributes(classification: :unreachable)
      expect(report.reachability.runtime_alive.map { |id| graph.nodes.fetch(id).symbol_id }).to include(
        'ScopeTarget#from_executable', 'ScopeTarget#from_initializer'
      )
      expect(report.reachability.test_alive.map { |id| graph.nodes.fetch(id).symbol_id }).to include(
        'ScopeTarget#from_test'
      )
      expect(report.diagnostics.fetch('analysis_scope')).to include(
        'reference_only_ruby_files' => contain_exactly(
          'config/initializers/scope_target.rb', 'exe/scope_tool', 'spec/scope_target_spec.rb'
        ),
        'reference_file_count' => 6
      )
      expect(graph.to_h.fetch('source_domains')).to include(
        'lib/scope_target.rb' => 'analyze', 'exe/scope_tool' => 'reference'
      )
    end
  end

  it 'does not let report filters remove graph nodes or edges' do
    files = {
      'lib/caller.rb' => 'class ScopedCaller; def run = ScopedTarget.new.call; end; end',
      'app/target.rb' => 'class ScopedTarget; def call; end; def dead; end; end'
    }
    common = { cache: { enabled: false }, entry_points: { extra: ['ScopedCaller#run'] } }

    with_project(files: files, config: common) do |root|
      unfiltered = Necropsy::Runner.new(root: root).analyze
      write_project_file(root, '.necropsy.yml', common.merge(report: { include: ['app/**'] }).to_yaml)
      filtered = Necropsy::Runner.new(root: root).analyze

      expect(filtered.graph.nodes.values.map(&:graph_id)).to eq(unfiltered.graph.nodes.values.map(&:graph_id))
      expect(filtered.graph.edges).to eq(unfiltered.graph.edges)
      expect(filtered.to_h.fetch('findings').map { |finding| finding.dig('node', 'file') }).to all(
        start_with('app/')
      )
    end
  end

  it 'blocks findings when production Ruby callers are excluded from reference scope' do
    files = {
      'lib/reference_target.rb' => <<~RUBY,
        class ReferenceTarget
          def called_outside; end
          def unknown_outside; end
        end
      RUBY
      'app/excluded_caller.rb' => 'ReferenceTarget.new.called_outside'
    }
    config = {
      cache: { enabled: false },
      paths: { analyze: ['lib/**'], reference: ['lib/**'] }
    }

    with_project(files: files, config: config) do |root|
      report = nil
      expect { report = Necropsy::Runner.new(root: root).analyze }.to output(
        %r{paths.reference excludes Ruby files.*app/excluded_caller.rb}m
      ).to_stderr

      expect(report.findings.map(&:classification)).to all(eq(:blocked))
      expect(report.findings.flat_map(&:blockers)).to include(
        have_attributes(kind: :reference_scope_incomplete, scope_kind: :global)
      )
      expect(report.findings.map(&:confidence)).to all(eq(:low))
    end
  end
end
