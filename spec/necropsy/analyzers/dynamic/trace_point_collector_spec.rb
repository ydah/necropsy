# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::TracePointCollector do
  it 'records runtime nodes and caller-callee edges' do
    with_project(files: {
                   'runner.rb' => <<~RUBY
                     class TracePointCollectorSample
                       def run
                         helper
                       end

                       def helper
                         :ok
                       end
                     end
                   RUBY
                 }) do |root|
      output = File.join(root, 'trace.yml')

      described_class.record(root: root, output: output) do
        load File.join(root, 'runner.rb')
        TracePointCollectorSample.new.run
      end

      payload = YAML.load_file(output)
      expect(payload.fetch('nodes')).to include('TracePointCollectorSample#run', 'TracePointCollectorSample#helper')
      expect(payload.fetch('node_references')).to include(
        include('symbol_id' => 'TracePointCollectorSample#run', 'file' => 'runner.rb', 'line' => be_a(Integer))
      )
      expect(payload.fetch('edges')).to include(
        'caller_id' => 'TracePointCollectorSample#run',
        'callee_id' => 'TracePointCollectorSample#helper'
      )
      expect(payload.fetch('edge_references')).to include(
        include(
          'caller_id' => include('symbol_id' => 'TracePointCollectorSample#run', 'file' => 'runner.rb'),
          'callee_id' => include('symbol_id' => 'TracePointCollectorSample#helper', 'file' => 'runner.rb')
        )
      )
    end
  end

  it 'keeps reopened runtime locations distinct in structured records' do
    with_project(files: {
                   'first.rb' => "class ReopenedTrace\n  def run = :first\nend\n",
                   'second.rb' => "class ReopenedTrace\n  def run = :second\nend\n"
                 }) do |root|
      output = File.join(root, 'trace.yml')

      described_class.record(root: root, output: output) do
        load File.join(root, 'first.rb')
        ReopenedTrace.new.run
        load File.join(root, 'second.rb')
        ReopenedTrace.new.run
      end

      payload = YAML.load_file(output)
      references = payload.fetch('node_references').select { |reference| reference['symbol_id'] == 'ReopenedTrace#run' }
      expect(payload.fetch('nodes').count('ReopenedTrace#run')).to eq(1)
      expect(references.map { |reference| reference['file'] }).to contain_exactly('first.rb', 'second.rb')
    end
  end

  it 'unwinds real multiline methods before a subsequent unrelated call' do
    with_project(files: {
                   'runner.rb' => <<~RUBY
                     class MultilineTraceFirst
                       def run
                         :first
                       end
                     end

                     class MultilineTraceSecond
                       def run
                         :second
                       end
                     end
                   RUBY
                 }) do |root|
      output = File.join(root, 'trace.yml')
      collector = described_class.new(root: root, output: output)

      collector.record do
        load File.join(root, 'runner.rb')
        MultilineTraceFirst.new.run
        MultilineTraceSecond.new.run
      end

      payload = YAML.load_file(output)
      expect(payload.fetch('nodes')).to include('MultilineTraceFirst#run', 'MultilineTraceSecond#run')
      expect(payload.fetch('edges')).to be_empty
      expect(payload.fetch('edge_references')).to be_empty
      expect(collector.instance_variable_get(:@stacks)).to be_empty
    end
  end

  it 'merges structured nodes and edges by location' do
    collector = described_class.new(root: '/repo', output: '/tmp/trace.yml')
    target = { 'symbol_id' => 'Target#call', 'file' => 'lib/target.rb', 'line' => 1 }
    first = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 2 }
    second = { 'symbol_id' => 'Reopened#run', 'file' => 'lib/a.rb', 'line' => 30 }
    left = {
      'nodes' => ['Reopened#run'], 'node_references' => [first],
      'edges' => [{ 'caller_id' => 'Reopened#run', 'callee_id' => 'Target#call' }],
      'edge_references' => [{ 'caller_id' => first, 'callee_id' => target }], 'observation' => {}
    }
    right = {
      'nodes' => ['Reopened#run'], 'node_references' => [second],
      'edges' => [{ 'caller_id' => 'Reopened#run', 'callee_id' => 'Target#call' }],
      'edge_references' => [{ 'caller_id' => second, 'callee_id' => target }], 'observation' => {}
    }

    merged = collector.send(:merge_payload, left, right)

    expect(merged.fetch('node_references')).to contain_exactly(first, second)
    expect(merged.fetch('edge_references').map { |edge| edge.fetch('caller_id') }).to contain_exactly(first, second)
    expect(merged.fetch('edges').length).to eq(1)
  end

  it 'keeps call stacks isolated between threads' do
    stub_const('TraceThreadA', Class.new)
    stub_const('TraceThreadB', Class.new)
    event = Struct.new(:path, :defined_class, :method_id, :event, keyword_init: true)

    with_project do |root|
      output = File.join(root, 'trace.yml')
      collector = described_class.new(root: root, output: output)
      collector.send(:capture, event.new(path: File.join(root, 'a.rb'), defined_class: TraceThreadA,
                                         method_id: :run, event: :call))
      Thread.new do
        collector.send(:capture, event.new(path: File.join(root, 'b.rb'), defined_class: TraceThreadB,
                                           method_id: :run, event: :call))
        collector.send(:capture, event.new(path: File.join(root, 'b.rb'), defined_class: TraceThreadB,
                                           method_id: :run, event: :return))
      end.join
      collector.send(:capture, event.new(path: File.join(root, 'a.rb'), defined_class: TraceThreadA,
                                         method_id: :run, event: :return))
      collector.send(:write_payload, started_at: Time.now.utc, finished_at: Time.now.utc)

      expect(YAML.load_file(output).fetch('edges')).to be_empty
    end
  end

  it 'samples on call and always consumes the matching return frame' do
    stub_const('TraceSampleA', Class.new)
    stub_const('TraceSampleB', Class.new)
    event = Struct.new(:path, :defined_class, :method_id, :event, keyword_init: true)
    allow(SecureRandom).to receive(:random_number).and_return(0.1, 0.1)

    with_project do |root|
      output = File.join(root, 'sampled.yml')
      collector = described_class.new(root: root, output: output, sample_rate: 0.5)
      collector.send(:capture, event.new(path: File.join(root, 'a.rb'), defined_class: TraceSampleA,
                                         method_id: :run, event: :call))
      collector.send(:capture, event.new(path: File.join(root, 'a.rb'), defined_class: TraceSampleA,
                                         method_id: :run, event: :return))
      collector.send(:capture, event.new(path: File.join(root, 'b.rb'), defined_class: TraceSampleB,
                                         method_id: :run, event: :call))
      collector.send(:write_payload, started_at: Time.now.utc, finished_at: Time.now.utc)

      payload = YAML.load_file(output)
      expect(payload.fetch('nodes')).to contain_exactly('TraceSampleA#run', 'TraceSampleB#run')
      expect(payload.fetch('edges')).to be_empty
      expect(SecureRandom).to have_received(:random_number).twice
    end
  end

  it 'pops the nearest recursive frame without using the return line' do
    stub_const('RecursiveTrace', Class.new)
    stub_const('UnrelatedTrace', Class.new)
    event = Struct.new(:path, :defined_class, :method_id, :event, :lineno, keyword_init: true)

    with_project do |root|
      collector = described_class.new(root: root, output: File.join(root, 'trace.yml'))
      path = File.join(root, 'runner.rb')
      call = event.new(path: path, defined_class: RecursiveTrace, method_id: :run, event: :call, lineno: 2)
      returned = event.new(path: path, defined_class: RecursiveTrace, method_id: :run, event: :return, lineno: 5)

      collector.send(:capture, call)
      collector.send(:capture, call)
      collector.send(:capture, returned)
      expect(collector.instance_variable_get(:@stacks).fetch(Thread.current).length).to eq(1)
      collector.send(:capture, returned)
      collector.send(
        :capture,
        event.new(path: path, defined_class: UnrelatedTrace, method_id: :run, event: :call, lineno: 9)
      )
      collector.send(
        :capture,
        event.new(path: path, defined_class: UnrelatedTrace, method_id: :run, event: :return, lineno: 12)
      )

      expect(collector.instance_variable_get(:@stacks)).to be_empty
      expect(collector.instance_variable_get(:@edges).keys).to eq(
        [['RecursiveTrace#run', 'RecursiveTrace#run']]
      )
      expect(collector.instance_variable_get(:@edge_references).values).to contain_exactly(
        include(
          'caller_id' => include('symbol_id' => 'RecursiveTrace#run', 'line' => 2),
          'callee_id' => include('symbol_id' => 'RecursiveTrace#run', 'line' => 2)
        )
      )
      recursive = collector.instance_variable_get(:@node_references).values.find do |reference|
        reference['symbol_id'] == 'RecursiveTrace#run'
      end
      expect(recursive).to include('file' => 'runner.rb', 'line' => 2)
    end
  end
end
