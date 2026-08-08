# frozen_string_literal: true

RSpec.describe 'dynamic collector overhead metadata' do
  it 'records Coverage collector work in schema v2 payloads' do
    with_project(files: { 'app/sample.rb' => "def sample_collector_method; end\n" }) do |root|
      output = File.join(root, 'coverage.yml')
      Necropsy::Analyzers::Dynamic::CoverageCollector.record(root: root, output: output) do
        2 + 2
      end

      payload = YAML.safe_load_file(output, aliases: false)
      expect(payload.dig('observation', 'collector_overhead')).to include('observed_nodes')
    end
  end

  it 'records TracePoint collector work in schema v2 payloads' do
    with_project(files: { 'app/sample.rb' => "def sample_trace_method; end\n" }) do |root|
      output = File.join(root, 'trace.yml')
      Necropsy::Analyzers::Dynamic::TracePointCollector.record(root: root, output: output) do
        2 + 2
      end

      payload = YAML.safe_load_file(output, aliases: false)
      expect(payload.dig('observation', 'collector_overhead')).to include('observed_edges')
    end
  end
end
