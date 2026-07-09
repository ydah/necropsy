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
      expect(payload.fetch('observation')).to include('collector' => 'coverage')
    end
  end
end
