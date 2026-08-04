# frozen_string_literal: true

class RunnerSpecAnalyzer < Necropsy::Analyzer
  def analyze(_graph, _project)
    Necropsy::AnalyzerResult.empty
  end

  def profile
    Necropsy::AnalyzerProfile.new(name: :runner_spec, kind: :static, soundness: :partial, description: 'spec')
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
      edge.callee_id if edge.caller_id == 'Caller#run' && edge.callee_id.end_with?('#render')
    end
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

  it 'loads custom analyzer classes from configuration' do
    with_project(
      files: { 'app/sample.rb' => 'class RunnerCustomSample; def dead; end; end' },
      config: { analyzers: { static: [], custom: ['RunnerSpecAnalyzer'] } }
    ) do |root|
      report = described_class.new(root: root).analyze

      expect(report.graph.profiles.map(&:name)).to eq([:runner_spec])
    end
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
    end
  end

  it 'keeps Runner reachability monotonic when an RTA edge is added to a rooted graph with allocation evidence' do
    common = { cache: { enabled: false }, entry_points: { extra: ['Caller#run'] } }
    without_rta = nil
    with_rta = nil

    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: %w[name_resolution cha] })
    ) do |root|
      without_rta = described_class.new(root: root).analyze.reachability.runtime_alive.to_set
    end
    with_project(files: { 'app/sample.rb' => rta_source }, config: common) do |root|
      with_rta = described_class.new(root: root).analyze.reachability.runtime_alive.to_set
    end

    expect(without_rta).to include('Caller#run', 'Base#render', 'Live#render', 'Dead#render')
    expect(without_rta - with_rta).to be_empty
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
    source = <<~RUBY
      autoload :Reflected, 'reflected'
      class Reflected
        def call; end
      end
      class Caller
        def build(name) = Object.const_get(name).new
        def run(item) = item.call
      end
    RUBY

    report = analyze_fixture(files: { 'app/reflective.rb' => source })

    expect(report.graph.instantiated_classes).not_to include('Reflected')
    expect(render_targets_for(report, 'call')).to include('Reflected#call')
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
    edge = report.graph.edges.find { |candidate| candidate.callee_id == 'Renderable#render' }

    expect(edge).not_to be_nil
    expect(edge.evidences.map(&:analyzer)).to include(:name_resolution, :cha)
  end

  it 'does not add high-confidence candidates when RTA is enabled' do
    common = {
      cache: { enabled: false },
      entry_points: { extra: ['Caller#run'] }
    }
    without_rta = nil
    with_rta = nil

    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: [] })
    ) do |root|
      without_rta = described_class.new(root: root).analyze.dead_methods(min_confidence: :high).map { |finding| finding.node.id }
    end
    with_project(
      files: { 'app/sample.rb' => rta_source },
      config: common.merge(analyzers: { static: ['rta'] })
    ) do |root|
      with_rta = described_class.new(root: root).analyze.dead_methods(min_confidence: :high).map { |finding| finding.node.id }
    end

    expect(without_rta).to include('Live#render')
    expect(with_rta).not_to include('Live#render')
    expect(with_rta - without_rta).to be_empty
  end

  def render_targets_for(report, message)
    report.graph.edges.filter_map do |edge|
      edge.callee_id if report.graph.nodes.fetch(edge.callee_id).name == message
    end.uniq
  end
end
