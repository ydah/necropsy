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
      expect { described_class.new(root: root).analyze }.to raise_error(Necropsy::Error, /Unknown static analyzer: typo/)
    end
  end
end
