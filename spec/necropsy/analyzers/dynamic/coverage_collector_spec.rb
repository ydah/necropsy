# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::CoverageCollector do
  it 'records method execution into a payload' do
    with_project(files: {
                   'runner.rb' => <<~RUBY
                     class CoverageCollectorSample
                       def run
                         :ok
                       end
                     end
                   RUBY
                 }) do |root|
      output = File.join(root, 'coverage.yml')

      described_class.record(root: root, output: output) do
        load File.join(root, 'runner.rb')
        CoverageCollectorSample.new.run
      end

      payload = YAML.load_file(output)
      expect(payload.fetch('nodes')).to include('CoverageCollectorSample#run')
      expect(payload.fetch('node_references')).to include(
        include('symbol_id' => 'CoverageCollectorSample#run', 'file' => 'runner.rb', 'line' => be_a(Integer))
      )
      expect(payload.fetch('observation')).to include('collector' => 'coverage')
    end
  end

  it 'warns when another collector started Coverage without method data' do
    collector = described_class.new(root: '/repo', output: '/tmp/coverage.yml')
    allow(Coverage).to receive(:running?).and_return(true)
    allow(Coverage).to receive(:peek_result).and_return('/repo/sample.rb' => [nil, 1])

    expect do
      expect(collector.send(:coverage_result, started: false)).to eq({})
    end.to output(/already running without methods: true/).to_stderr
  end

  it 'merges structured locations without collapsing reopened logical methods' do
    collector = described_class.new(root: '/repo', output: '/tmp/coverage.yml')
    left = {
      'nodes' => ['Reopened#run'],
      'node_references' => [{ 'symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 2 }],
      'observation' => { 'days' => 1 }
    }
    right = {
      'nodes' => ['Reopened#run'],
      'node_references' => [{ 'symbol_id' => 'Reopened#run', 'file' => 'lib/b.rb', 'line' => 3 }],
      'observation' => { 'days' => 1 }
    }

    merged = collector.send(:merge_payload, left, right)

    expect(merged.fetch('nodes')).to eq(['Reopened#run'])
    expect(merged.fetch('node_references')).to contain_exactly(
      include('symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 2),
      include('symbol_id' => 'Reopened#run', 'file' => 'lib/b.rb', 'line' => 3)
    )
  end
end
