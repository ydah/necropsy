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
end
