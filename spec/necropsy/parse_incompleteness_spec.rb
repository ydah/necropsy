# frozen_string_literal: true

RSpec.describe 'parse incompleteness' do
  let(:recovered_source) do
    <<~RUBY
      class RecoveredSource
        def retained
        end

        private

        def hidden
        end

        def broken(
        end
      end
    RUBY
  end

  def candidates(report, min_confidence: :low)
    report.findings.select do |finding|
      finding.classification != :blocked && finding.at_least?(min_confidence)
    end.to_set { |finding| finding.node.id }
  end

  it 'records Prism recovery and blocks every definition retained in the partial AST' do
    with_project(
      files: { 'lib/recovered_source.rb' => recovered_source },
      config: { cache: { enabled: false } }
    ) do |root|
      report = Necropsy.analyze(root: root)
      graph = report.graph
      findings = report.findings.to_h { |finding| [finding.node.id, finding] }

      expect(graph.file_statuses).to eq('lib/recovered_source.rb' => :recovered)
      expect(graph.source_errors.first.to_h).to include(
        'file' => 'lib/recovered_source.rb',
        'line' => 11,
        'type' => 'def_params_term_paren'
      )
      expect(findings.keys).to include('RecoveredSource#retained', 'RecoveredSource#hidden')
      expect(findings.values).to all(have_attributes(classification: :blocked, confidence: :low))
      findings.each_value do |finding|
        expect(finding.blockers).to include(
          have_attributes(kind: :parse_incomplete, scope_kind: :file, scope_value: 'lib/recovered_source.rb'),
          have_attributes(kind: :parse_incomplete, scope_kind: :global, scope_value: '*')
        )
      end
      expect(report.summary).to include('incomplete_files' => 1, 'blocked' => findings.length)
      expect(report.to_h(include_graph: true).fetch('graph')).to include(
        'file_statuses' => { 'lib/recovered_source.rb' => 'recovered' },
        'source_errors' => [include('file' => 'lib/recovered_source.rb', 'line' => 11)]
      )
    end
  end

  it 'keeps alive evidence usable while showing incomplete source locations in reports and diagnostics' do
    with_project(
      files: { 'lib/recovered_source.rb' => recovered_source },
      config: {
        cache: { enabled: false },
        entry_points: { extra: ['RecoveredSource#retained'] }
      }
    ) do |root|
      report = Necropsy.analyze(root: root)
      diagnostics = Necropsy::Diagnostics.new(report)
      why = diagnostics.why('RecoveredSource#retained')
      explain = diagnostics.explain('RecoveredSource#hidden')
      human_report = Necropsy::Reporter.new(report).render(min_confidence: :low)

      expect(why).to include('status' => 'alive')
      expect(why.dig('source_incompleteness', 'incomplete_files')).to eq(1)
      expect(explain).to include('status' => 'finding', 'classification' => 'blocked')
      expect(explain.dig('source_incompleteness', 'files', 0, 'errors', 0)).to include(
        'file' => 'lib/recovered_source.rb', 'line' => 11
      )
      expect(diagnostics.render(why)).to include(
        'Incomplete source files: 1', 'lib/recovered_source.rb:11 [def_params_term_paren]'
      )
      expect(human_report).to include(
        'Incomplete source files: 1', 'Incomplete source: lib/recovered_source.rb:11'
      )
    end
  end

  it 'records invalid source encoding as a recovered Prism error' do
    source = "class InvalidEncoding; def retained; end; end\n\xFF".b

    with_project(files: { 'lib/invalid_encoding.rb' => source }) do |root|
      scan = scan_project(root)

      expect(scan.file_statuses).to eq('lib/invalid_encoding.rb' => :recovered)
      expect(scan.nodes.map(&:id)).to include('InvalidEncoding#retained')
      expect(scan.source_errors.map(&:to_h)).to include(
        include('file' => 'lib/invalid_encoding.rb', 'line' => 2, 'type' => 'invalid_multibyte_character')
      )
    end
  end

  it 'records read and encoding exceptions instead of silently skipping files' do
    [Errno::EACCES.new('spec read failure'), EncodingError.new('spec encoding failure')].each do |failure|
      with_project(files: { 'lib/unreadable.rb' => 'class Unreadable; end' }) do |root|
        project = project_for(root)
        path = File.join(root, 'lib/unreadable.rb')
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(path).and_raise(failure)

        scan = Necropsy::AstScanner.new(project: project, files: [path]).scan

        expect(scan.file_statuses).to eq('lib/unreadable.rb' => :failed)
        expect(scan.source_errors.first.to_h).to include(
          'file' => 'lib/unreadable.rb', 'line' => 1, 'type' => failure.class.name
        )
        expect(scan.source_errors.first.type).to be_a(Symbol)
        expect(scan.uncertainties.fetch('file:lib/unreadable.rb')).to include(match(/spec .* failure/))
      end
    end
  end

  it 'turns identity limits into test-scoped source failures' do
    with_project(files: { 'spec/deep_spec.rb' => "describe 'deep' do; end\n" }) do |root|
      project = project_for(root)
      allow(Necropsy::DefinitionIdentity).to receive(:body_digest).and_raise(
        Necropsy::DefinitionIdentity::LimitExceeded,
        'canonical depth exceeded'
      )

      scan = Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
      graph = Necropsy::CallGraph.new(scan)

      expect(scan.file_statuses).to eq('spec/deep_spec.rb' => :failed)
      expect(scan.source_errors.first.type).to eq(:'Necropsy::DefinitionIdentity::LimitExceeded')
      expect(graph.blockers).to contain_exactly(
        have_attributes(
          kind: :parse_incomplete,
          scope_kind: :file,
          scope_value: 'spec/deep_spec.rb',
          caller_domain: :test
        )
      )
    end
  end

  it 'matches failed file blockers to private definitions supplied by a scan result' do
    failed = node('FailedSource#hidden', file: 'lib/failed_source.rb', visibility: :private)
    error = Necropsy::SourceError.new(
      file: 'lib/failed_source.rb', line: 1, message: 'permission denied', type: 'Errno::EACCES'
    )
    result = scan_result(nodes: [failed]).with(
      file_statuses: { 'lib/failed_source.rb' => :failed },
      source_errors: [error]
    )
    graph = Necropsy::CallGraph.new(result)

    expect(graph.matching_blockers(failed)).to contain_exactly(
      have_attributes(kind: :parse_incomplete, scope_kind: :file, scope_value: 'lib/failed_source.rb'),
      have_attributes(kind: :parse_incomplete, scope_kind: :global, scope_value: '*')
    )
  end

  it 'blocks a callee in another file when recovery loses its outgoing call' do
    target = "class Target\n  def used; end\nend\n"
    valid_caller = "class Caller\n  def run\n    Target.new.used\n  end\nend\n"
    broken_caller = "class Caller\n  def run\n    Target.new.\n  end\nend\n"
    config = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }
    complete_report = nil
    recovered_report = nil

    with_project(files: { 'lib/caller.rb' => valid_caller, 'lib/target.rb' => target }, config: config) do |root|
      complete_report = Necropsy.analyze(root: root)
    end
    with_project(files: { 'lib/caller.rb' => broken_caller, 'lib/target.rb' => target }, config: config) do |root|
      recovered_report = Necropsy.analyze(root: root)
    end

    recovered_target = recovered_report.findings.find { |finding| finding.node.id == 'Target#used' }
    expect(complete_report.findings.map { |finding| finding.node.id }).not_to include('Target#used')
    expect(recovered_target).to have_attributes(classification: :blocked, confidence: :low)
    expect(recovered_target.blockers).to include(
      have_attributes(kind: :parse_incomplete, scope_kind: :global, scope_value: '*')
    )
    expect(candidates(recovered_report)).to be_subset(candidates(complete_report))
    expect(candidates(recovered_report, min_confidence: :high)).to be_subset(
      candidates(complete_report, min_confidence: :high)
    )
  end

  it 'does not propagate an incomplete test source into production findings' do
    files = { 'lib/target.rb' => "class TestIsolationTarget\n  def candidate; end\nend\n" }
    config = { cache: { enabled: false } }
    baseline = nil
    with_broken_test = nil

    with_project(files: files, config: config) { |root| baseline = Necropsy.analyze(root: root) }
    with_project(files: files.merge('spec/broken_spec.rb' => ")\n"), config: config) do |root|
      with_broken_test = Necropsy.analyze(root: root)
    end

    baseline_finding = baseline.findings.find { |finding| finding.node.id == 'TestIsolationTarget#candidate' }
    isolated_finding = with_broken_test.findings.find { |finding| finding.node.id == 'TestIsolationTarget#candidate' }
    expect(isolated_finding).to have_attributes(
      classification: baseline_finding.classification,
      confidence: baseline_finding.confidence,
      blockers: []
    )
    global_blockers = with_broken_test.graph.blockers.select { |blocker| blocker.scope_kind == :global }
    expect(global_blockers).to eq([])
  end

  it 'never adds candidates or high-confidence findings when a parse error is introduced' do
    valid = <<~RUBY
      class MonotonicSource
        def retained
        end
      end
    RUBY
    broken = "#{valid}def broken(\n"
    complete_report = nil
    recovered_report = nil

    with_project(files: { 'lib/monotonic_source.rb' => valid }, config: { cache: { enabled: false } }) do |root|
      complete_report = Necropsy.analyze(root: root)
    end
    with_project(files: { 'lib/monotonic_source.rb' => broken }, config: { cache: { enabled: false } }) do |root|
      recovered_report = Necropsy.analyze(root: root)
    end

    expect(candidates(recovered_report)).to be_subset(candidates(complete_report))
    expect(candidates(recovered_report, min_confidence: :high)).to be_subset(
      candidates(complete_report, min_confidence: :high)
    )
  end

  it 'produces the same incomplete-source report with a cold, warm, or disabled cache' do
    with_project(
      files: { 'lib/recovered_source.rb' => recovered_source },
      config: { cache: { enabled: true } }
    ) do |root|
      cold = Necropsy.analyze(root: root).to_h(include_graph: true)
      warm = Necropsy.analyze(root: root).to_h(include_graph: true)
      write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)
      uncached = Necropsy.analyze(root: root).to_h(include_graph: true)

      expect(warm).to eq(cold)
      expect(uncached.except('source_snapshot')).to eq(cold.except('source_snapshot'))
      expect(uncached.dig('source_snapshot', 'verification', 'status')).to eq('match')
    end
  end
end
