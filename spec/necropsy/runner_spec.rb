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
    end
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
end
