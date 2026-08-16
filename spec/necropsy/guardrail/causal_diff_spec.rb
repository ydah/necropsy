# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Diff do
  it 'reports physical candidate transitions and proof context' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.json')
      head = File.join(directory, 'head.json')
      base_payload = {
        'artifact_provenance' => { 'producer' => { 'version' => '0.3.0' } },
        'analysis_health' => { 'status' => 'complete' },
        'findings' => [],
        'graph' => { 'nodes' => [], 'edges' => [], 'entry_points' => [], 'resolutions' => [] }
      }
      head_payload = base_payload.merge(
        'findings' => [{
          'classification' => 'unreachable', 'actionability' => 'review_candidate', 'confidence' => 'medium',
          'node' => {
            'definition_id' => 'def:dead', 'symbol_id' => 'Service#dead', 'file' => 'lib/service.rb', 'line' => 4
          }, 'blockers' => []
        }],
        'graph' => {
          'nodes' => [{ 'definition_id' => 'def:dead', 'symbol_id' => 'Service#dead' }],
          'edges' => [{ 'caller_id' => 'def:caller', 'callee_id' => 'def:dead' }],
          'entry_points' => [], 'resolutions' => []
        }
      )
      File.write(base, JSON.pretty_generate(base_payload))
      File.write(head, JSON.pretty_generate(head_payload))

      result = described_class.compare_reports(base_path: base, head_path: head)

      expect(result.fetch('newly_unreachable')).to include(
        include(
          'definition_id' => 'def:dead',
          'last_incoming_edge' => include('caller_id' => 'def:caller'),
          'proof_obligations' => include('dispatch')
        )
      )
    end
  end
end
