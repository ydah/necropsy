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
end
