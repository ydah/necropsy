# frozen_string_literal: true

RSpec.describe 'Necropsy report JSON Schema' do
  subject(:schema) { JSON.parse(File.read(Necropsy::Report.schema_path)) }

  let(:report) do
    candidate = finding(id: 'SchemaSample#dead', classification: :unreachable, confidence: :high)
    graph = graph_with(nodes: [candidate.node])
    Necropsy::Report.new(root: '/repo', graph: graph, findings: [candidate])
  end

  it 'publishes the versioned draft 2020-12 contract from the packaged path' do
    expect(File.basename(Necropsy::Report.schema_path)).to eq('necropsy-report-v2.schema.json')
    expect(schema).to include(
      '$schema' => 'https://json-schema.org/draft/2020-12/schema',
      'title' => 'Necropsy report v2'
    )
    expect(schema.dig('properties', 'schema_version')).to eq('const' => Necropsy::Report::SCHEMA_VERSION)
  end

  it 'keeps report, finding, health, and summary required fields aligned with serialization' do
    payload = report.to_h(include_graph: true)
    required_groups = {
      schema => payload,
      schema.dig('$defs', 'finding') => payload.fetch('findings').first,
      schema.dig('$defs', 'analysisHealth') => payload.fetch('analysis_health'),
      schema.dig('$defs', 'summary') => payload.fetch('summary'),
      schema.dig('$defs', 'graph') => payload.fetch('graph')
    }

    required_groups.each do |contract, value|
      expect(value.keys).to include(*contract.fetch('required'))
    end
    finding_contract = schema.dig('$defs', 'finding', 'properties')
    expect(finding_contract.dig('classification', 'enum')).to include(payload.dig('findings', 0, 'classification'))
    expect(finding_contract.dig('confidence', 'enum')).to include(payload.dig('findings', 0, 'confidence'))
  end
end
