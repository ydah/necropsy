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
      expect(payload.fetch('edges')).to include(
        'caller_id' => 'TracePointCollectorSample#run',
        'callee_id' => 'TracePointCollectorSample#helper'
      )
    end
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
end
