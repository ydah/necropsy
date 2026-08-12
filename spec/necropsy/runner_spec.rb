# frozen_string_literal: true

class RunnerSpecAnalyzer < Necropsy::Analyzer
  def analyze(_graph, _project)
    Necropsy::AnalyzerResult.empty
  end

  def profile
    Necropsy::AnalyzerProfile.new(name: :runner_spec, kind: :static, soundness: :partial, description: 'spec')
  end
end

class LegacyWeightedRunnerAnalyzer < Necropsy::Analyzer
  def initialize(weight)
    @weight = weight
  end

  def analyze(graph, _project)
    site = graph.call_sites.find { |candidate| candidate.message == 'call' }
    target = graph.candidate_nodes('call').find { |candidate| candidate.owner == 'Target' }
    edge = Necropsy::EdgeEvidence.new(
      caller_id: site.caller_id,
      callee_id: target.graph_id,
      evidence: Necropsy::Evidence.new(
        analyzer: :legacy_weighted,
        kind: :call_edge,
        weight: @weight,
        details: 'legacy weighted edge',
        metadata: site.to_h.except('call_site_id')
      )
    )
    Necropsy::AnalyzerResult.new(
      edge_evidences: [edge], alive_evidences: [], uncertainties: {}, observation: {}
    )
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :legacy_weighted, kind: :static, soundness: :partial, description: 'legacy weighted analyzer'
    )
  end
end

class CyclicMetadataRunnerAnalyzer < Necropsy::Analyzer
  def analyze(*)
    cyclic = {}
    cyclic['self'] = cyclic
    send(:evidence, kind: :call_edge, details: 'cyclic metadata', metadata: cyclic)
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :cyclic_metadata, kind: :static, soundness: :partial, description: 'cyclic metadata', version: '1'
    )
  end
end

class InvalidMessageRunnerAnalyzer < Necropsy::Analyzer
  def analyze(*)
    raise "\xFF".b + ('x' * 10_000)
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :invalid_message, kind: :static, soundness: :partial, description: 'invalid message', version: '1'
    )
  end
end

class SourceMutatingRunnerAnalyzer < Necropsy::Analyzer
  def analyze(_graph, project)
    File.write(File.join(project.root, 'app/sample.rb'), 'class ChangedDuringAnalysis; def newer; end; end')
    Necropsy::AnalyzerResult.empty
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :source_mutating, kind: :static, soundness: :partial, description: 'mutates the source under analysis'
    )
  end
end

class UnprovenCompleteRunnerAnalyzer < Necropsy::Analyzer
  def analyze(graph, _project)
    site = graph.call_sites.fetch(0)
    Necropsy::AnalyzerResult.new(
      edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {},
      resolutions: [
        Necropsy::ResolutionRecord.new(
          resolution: Necropsy::Resolution.new(
            call_site_id: site.call_site_id, target_definition_ids: [], status: :complete
          ),
          producer: :unproven_complete,
          producer_version: '1',
          assumptions: []
        )
      ]
    )
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :unproven_complete, kind: :static, soundness: :partial,
      description: 'attempts an unproven complete resolution', version: '1'
    )
  end
end

RSpec.describe Necropsy::Runner do
  let(:rta_source) do
    <<~RUBY
      class Base
        # necropsy:quarantine since=2020-01-01
        def render; end
      end

      class Live < Base
        # necropsy:quarantine since=2020-01-01
        def render; end
      end

      class Dead < Base
        # necropsy:quarantine since=2020-01-01
        def render; end
      end

      class Caller
        def run(receiver)
          receiver.render
        end
      end

      Live.new
    RUBY
  end

  def render_targets(report)
    report.graph.edges.filter_map do |edge|
      caller = report.graph.nodes.fetch(edge.caller_id)
      callee = report.graph.nodes.fetch(edge.callee_id)
      callee.symbol_id if caller.symbol_id == 'Caller#run' && callee.symbol_id.end_with?('#render')
    end
  end

  def logical_reachable(report)
    report.reachability.runtime_alive.to_set { |graph_id| report.graph.nodes.fetch(graph_id).symbol_id }
  end

  def analyze_fixture(files:, config: {})
    with_project(files: files, config: { cache: { enabled: false } }.merge(config)) do |root|
      return described_class.new(root: root).analyze
    end
  end

  it 'uses explicitly supplied analyzers instead of configured defaults' do
    with_project(files: { 'app/sample.rb' => 'class RunnerSample; def dead; end; end' }) do |root|
      report = described_class.new(root: root, analyzers: [RunnerSpecAnalyzer.new]).analyze

      expect(report.graph.profiles.map(&:name)).to eq([:runner_spec])
      expect(report.findings.map(&:node).map(&:id)).to include('RunnerSample#dead')
    end
  end

  it 'turns cyclic analyzer metadata into a bounded failure blocker' do
    with_project(files: { 'app/sample.rb' => 'class RunnerSample; def dead; end; end' }) do |root|
      report = described_class.new(root: root, analyzers: [CyclicMetadataRunnerAnalyzer.new]).analyze
      blocker = report.graph.blockers.find { |candidate| candidate.kind == :analyzer_failure }

      expect(blocker).to have_attributes(source: 'cyclic_metadata')
      expect(blocker.metadata.fetch('error_class')).to eq('Necropsy::BoundedCanonicalizer::CycleError')
      expect(report.analysis_health).to have_attributes(status: :invalid)
      expect(report.analysis_health.reasons).to include(include('code' => 'analyzer_failure'))
      expect(report.to_h.fetch('analysis_health')).to include('status' => 'invalid')
      expect { report.to_json(include_graph: true) }.not_to raise_error
    end
  end

  it 'rejects complete resolutions from analyzers without an explicit capability' do
    source = 'class UnprovenCaller; def run; missing_target; end; end'
    with_project(files: { 'app/sample.rb' => source }, config: { cache: { enabled: false } }) do |root|
      report = described_class.new(root: root, analyzers: [UnprovenCompleteRunnerAnalyzer.new]).analyze

      expect(report.analysis_health).to have_attributes(status: :invalid)
      expect(report.graph.blockers).to include(
        have_attributes(kind: :analyzer_failure, reason: match(/complete_resolution capability/))
      )
      expect(report.findings).to all(have_attributes(classification: :blocked))
    end
  end

  it 'verifies that the source snapshot still matches after analysis' do
    with_project(files: { 'app/sample.rb' => 'class StableSource; def dead; end; end' }) do |root|
      report = described_class.new(root: root, analyzers: [RunnerSpecAnalyzer.new]).analyze

      expect(report.analysis_health).to have_attributes(status: :complete, reasons: [])
      expect(report.source_snapshot.fetch('verification')).to include('status' => 'match')
    end
  end

  it 'invalidates analysis when source changes after scanning' do
    with_project(files: { 'app/sample.rb' => 'class InitialSource; def older; end; end' }) do |root|
      report = described_class.new(root: root, analyzers: [SourceMutatingRunnerAnalyzer.new]).analyze

      expect(report.analysis_health).to have_attributes(status: :invalid)
      expect(report.analysis_health.reasons).to include(include('code' => 'source_changed_during_analysis'))
      expect(report.source_snapshot.fetch('verification')).to include('status' => 'mismatch')
      expect(report.graph.method_nodes.map(&:symbol_id)).to include('InitialSource#older')
      expect(report.graph.method_nodes.map(&:symbol_id)).not_to include('ChangedDuringAnalysis#newer')
    end
  end

  it 'bounds and sanitizes invalid analyzer failure messages for JSON output' do
    with_project(files: { 'app/sample.rb' => 'class RunnerSample; def dead; end; end' }) do |root|
      report = described_class.new(root: root, analyzers: [InvalidMessageRunnerAnalyzer.new]).analyze
      blocker = report.graph.blockers.find { |candidate| candidate.kind == :analyzer_failure }
      message = blocker.metadata.fetch('error_message')

      expect(message.encoding).to eq(Encoding::UTF_8)
      expect(message).to be_valid_encoding
      expect(message.bytesize).to be <= (Necropsy::Runner::ANALYZER_ERROR_MESSAGE_BYTES + 3)
      expect { report.to_json(include_graph: true) }.not_to raise_error
    end
  end

  it 'loads custom analyzer classes from configuration' do
    with_project(
      files: { 'app/sample.rb' => 'class RunnerCustomSample; def dead; end; end' },
      config: { analyzers: { static: [], custom: ['RunnerSpecAnalyzer'] } }
    ) do |root|
      report = described_class.new(root: root).analyze

      expect(report.graph.profiles.map(&:name)).to eq([:runner_spec])
    end
  end

  it 'adapts legacy custom analyzers without making findings depend on evidence weight' do
    source = <<~RUBY
      class Target
        def call; end
      end
      class Other
        def call; end
      end
      class Caller
        def run = Target.new.call
      end
    RUBY
    reports = [0.01, 100.0].map do |weight|
      report = nil
      with_project(files: { 'app/sample.rb' => source }) do |root|
        report = described_class.new(root: root, analyzers: [LegacyWeightedRunnerAnalyzer.new(weight)]).analyze
      end
      report
    end

    resolutions = reports.map do |report|
      report.graph.resolution_records.map do |record|
        [record.resolution.status, record.resolution.target_definition_ids]
      end
    end
    findings = reports.map do |report|
      report.findings.map { |finding| [finding.node.symbol_id, finding.classification] }
    end

    expect(resolutions.first).to eq(resolutions.last)
    expect(resolutions.first).to include(satisfy { |status, targets| status == :partial && targets.one? })
    expect(reports.first.graph.resolution_records.map(&:producer_version).uniq).to eq(['unversioned'])
    expect(findings.first).to eq(findings.last)
    expect(findings.first).to include(['Other#call', :blocked])
  end

  it 'raises a Necropsy error for missing custom analyzers' do
    with_project(config: { analyzers: { custom: ['MissingAnalyzer'] } }) do |root|
      expect { described_class.new(root: root).analyze }.to raise_error(
        Necropsy::Error,
        /Could not load custom analyzer MissingAnalyzer/
      )
    end
  end

  it 'requires custom analyzer implementations declared in configuration' do
    source = <<~RUBY
      class RequiredRunnerAnalyzer < Necropsy::Analyzer
        def analyze(*) = Necropsy::AnalyzerResult.empty
        def profile = Necropsy::AnalyzerProfile.new(name: :required, kind: :static, soundness: :partial, description: 'required')
      end
    RUBY
    with_project(
      files: { 'config/required_analyzer.rb' => source },
      config: {
        analyzers: {
          static: [],
          custom: [{ class: 'RequiredRunnerAnalyzer', require: 'config/required_analyzer.rb' }]
        }
      }
    ) do |root|
      report = described_class.new(root: root).analyze

      expect(report.graph.profiles.map(&:name)).to eq([:required])
    end
  end

  it 'rejects unknown static analyzer names' do
    with_project(config: { analyzers: { static: ['typo'] } }) do |root|
      expect do
        described_class.new(root: root).analyze
      end.to raise_error(Necropsy::Error, /Unknown static analyzer: typo/)
    end
  end

  it 'retains name-resolution and CHA edges with default rank-only RTA' do
    with_project(files: { 'app/sample.rb' => rta_source }, config: { cache: { enabled: false } }) do |root|
      report = described_class.new(root: root).analyze

      expect(render_targets(report)).to contain_exactly('Base#render', 'Live#render', 'Dead#render')
    end
  end

  it 'reconciles static edges only when legacy RTA pruning is configured' do
    config = { cache: { enabled: false }, rta: { pruning: 'legacy' } }

    with_project(files: { 'app/sample.rb' => rta_source }, config: config) do |root|
      report = described_class.new(root: root).analyze

      expect(render_targets(report)).to eq(['Live#render'])
      expect(report.graph.profiles.find { |profile| profile.name == :rta }.description).to include('mode legacy')
      expect(report.graph.observation.dig('rta', 'pruning')).to eq('legacy')
      expect(report.analysis_health).to have_attributes(status: :invalid)
      expect(report.analysis_health.reasons).to include(include('code' => 'unsound_rta_pruning'))
    end
  end

  it 'does not reduce Runner reachability when RTA static-edge evidence is added' do
    common = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }
    without_rta = nil
    with_rta = nil

    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: %w[name_resolution cha] })
    ) do |root|
      report = described_class.new(root: root).analyze
      without_rta = logical_reachable(report)
    end
    with_project(files: { 'app/sample.rb' => rta_source }, config: common) do |root|
      report = described_class.new(root: root).analyze
      with_rta = logical_reachable(report)
    end

    expect(without_rta).to include('Caller#run', 'Base#render', 'Live#render', 'Dead#render')
    expect(without_rta - with_rta).to be_empty
  end

  it 'does not reduce Runner reachability when a root is added' do
    before = analyze_fixture(files: { 'app/sample.rb' => rta_source })
    after = analyze_fixture(
      files: { 'app/sample.rb' => rta_source },
      config: { entry_points: { extra: ['Caller#run'] } }
    )
    before_reachable = logical_reachable(before)
    after_reachable = logical_reachable(after)

    expect(before_reachable).to be_empty
    expect(after_reachable).to include('Caller#run', 'Base#render', 'Live#render', 'Dead#render')
    expect(before_reachable - after_reachable).to be_empty
  end

  it 'does not reduce Runner reachability when allocation evidence is added' do
    without_allocation = rta_source.sub("\nLive.new\n", "\n")
    config = { entry_points: { extra: ['Caller#run'] } }
    before = analyze_fixture(files: { 'app/sample.rb' => without_allocation }, config: config)
    after = analyze_fixture(files: { 'app/sample.rb' => rta_source }, config: config)
    before_reachable = logical_reachable(before)
    after_reachable = logical_reachable(after)

    expect(before.graph.instantiated_classes).not_to include('Live')
    expect(after.graph.instantiated_classes).to include('Live')
    expect(before_reachable - after_reachable).to be_empty
  end

  it 'preserves static edges when a factory method is not registered' do
    source = <<~RUBY
      class FactoryBuilt
        def call; end
      end
      class Caller
        def run
          built = FactoryBuilt.spawn
          built.call
        end
      end
    RUBY

    report = analyze_fixture(files: { 'app/factory.rb' => source })

    expect(report.graph.instantiated_classes).not_to include('FactoryBuilt')
    expect(render_targets_for(report, 'call')).to include('FactoryBuilt#call')
  end

  it 'preserves static edges around reflective and autoloaded construction' do
    caller_source = <<~RUBY
      autoload :AutoloadedService, 'autoloaded_service'
      class Caller
        def build(name) = Object.const_get(name).new
        def run(item) = item.call
      end
    RUBY
    service_source = <<~RUBY
      class AutoloadedService
        def call; end
      end
    RUBY

    report = analyze_fixture(
      files: {
        'app/caller.rb' => caller_source,
        'app/autoloaded_service.rb' => service_source
      }
    )

    expect(report.graph.instantiated_classes).not_to include('AutoloadedService')
    expect(render_targets_for(report, 'call')).to include('AutoloadedService#call')
  end

  it 'does not let test-only instantiation prune other application targets' do
    source = <<~RUBY
      class TestBuilt
        def call; end
      end
      class OtherBuilt
        def call; end
      end
      class Caller
        def run(item) = item.call
      end
    RUBY
    report = analyze_fixture(
      files: { 'app/services.rb' => source, 'spec/service_spec.rb' => 'TestBuilt.new' }
    )

    expect(report.graph.instantiated_classes).to include('TestBuilt')
    expect(render_targets_for(report, 'call')).to contain_exactly('TestBuilt#call', 'OtherBuilt#call')
  end

  it 'preserves module method lookup when allocation evidence cannot identify the including class' do
    source = <<~RUBY
      module Renderable
        def render; end
      end
      class Worker
        include Renderable
      end
      class Caller
        def run(worker) = worker.render
      end
      Worker.new
    RUBY
    report = analyze_fixture(files: { 'app/module_lookup.rb' => source })
    edge = report.graph.edges.find do |candidate|
      report.graph.nodes.fetch(candidate.callee_id).symbol_id == 'Renderable#render'
    end

    expect(edge).not_to be_nil
    expect(edge.evidences.map(&:analyzer)).to include(:name_resolution, :cha)
  end

  it 'does not add high-confidence candidates when RTA is enabled' do
    common = {
      cache: { enabled: false },
      entry_points: { extra: ['Caller#run'] }
    }
    without_rta_report = nil
    with_rta_report = nil

    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: [] })
    ) do |root|
      without_rta_report = described_class.new(root: root).analyze
    end
    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: ['rta'] })
    ) do |root|
      with_rta_report = described_class.new(root: root).analyze
    end

    without_rta_candidates = without_rta_report.dead_methods(min_confidence: :low).map { |finding| finding.node.id }
    with_rta_candidates = with_rta_report.dead_methods(min_confidence: :low).map { |finding| finding.node.id }
    expect(without_rta_candidates).to include('Live#render')
    expect(with_rta_candidates).not_to include('Live#render')

    without_rta_high = without_rta_report.dead_methods(min_confidence: :high).map { |finding| finding.node.id }
    with_rta_high = with_rta_report.dead_methods(min_confidence: :high).map { |finding| finding.node.id }
    expect(with_rta_high - without_rta_high).to be_empty
  end

  it 'turns ambiguity-limit truncation into blocked findings instead of unreachable candidates' do
    handlers = 5.times.map do |index|
      "class Handler#{index}; def call; end; end"
    end.join("\n")
    source = <<~RUBY
      #{handlers}
      class Caller
        def run(handler) = handler.call
      end
    RUBY
    common = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }
    limited = analyze_fixture(
      files: { 'app/dispatch.rb' => source },
      config: common.merge(resolution: { ambiguity_limit: 4 })
    )
    unlimited = analyze_fixture(
      files: { 'app/dispatch.rb' => source },
      config: common.merge(resolution: { ambiguity_limit: 'unlimited' })
    )

    limited_handlers = limited.findings.select { |finding| finding.node.name == 'call' }
    unlimited_handlers = unlimited.findings.select { |finding| finding.node.name == 'call' }

    expect(limited_handlers.length).to eq(5)
    expect(limited_handlers).to all(have_attributes(classification: :blocked, confidence: :low))
    expect(limited_handlers).to all(satisfy { |finding| !finding.at_least?(:high) })
    expect(unlimited_handlers).to eq([])
    truncation = limited.graph.blockers.find { |blocker| blocker.metadata['candidate_count'] == 5 }
    expect(truncation.metadata).to include('candidate_count' => 5, 'ambiguity_limit' => 4)
  end

  it 'blocks private targets when reflective dispatch exceeds the ambiguity limit' do
    reflective_calls = {
      '__send__' => 'receiver.__send__(:hidden)',
      'method' => 'receiver.method(:hidden)',
      'respond_to?_private' => 'receiver.respond_to?(:hidden, true)'
    }
    handlers = 5.times.map do |index|
      "class Handler#{index}; private; def hidden; end; end"
    end.join("\n")
    common = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }

    reflective_calls.each do |api, invocation|
      source = <<~RUBY
        #{handlers}
        class Caller
          def run(receiver)
            #{invocation}
          end
        end
      RUBY
      limited = analyze_fixture(
        files: { "app/#{api}.rb" => source },
        config: common.merge(resolution: { ambiguity_limit: 4 })
      )
      unlimited = analyze_fixture(
        files: { "app/#{api}.rb" => source },
        config: common.merge(resolution: { ambiguity_limit: 'unlimited' })
      )

      limited_targets = limited.findings.select { |finding| finding.node.name == 'hidden' }
      unlimited_targets = unlimited.findings.select { |finding| finding.node.name == 'hidden' }
      limited_unreachable = limited_targets.select { |finding| finding.classification == :unreachable }.to_set(&:node)
      unlimited_unreachable = unlimited_targets.select { |finding| finding.classification == :unreachable }.to_set(&:node)
      limited_high = limited_targets.select { |finding| finding.at_least?(:high) }.to_set(&:node)
      unlimited_high = unlimited_targets.select { |finding| finding.at_least?(:high) }.to_set(&:node)

      expect(limited_targets).to all(have_attributes(classification: :blocked, confidence: :low)), api
      expect(limited_unreachable).to be_subset(unlimited_unreachable), api
      expect(limited_high).to be_subset(unlimited_high), api
      expect(unlimited_targets).to eq([]), api
    end
  end

  def render_targets_for(report, message)
    report.graph.edges.filter_map do |edge|
      node = report.graph.nodes.fetch(edge.callee_id)
      node.symbol_id if node.name == message
    end.uniq
  end
end
