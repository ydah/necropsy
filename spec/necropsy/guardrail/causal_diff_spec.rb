# frozen_string_literal: true

require 'necropsy/cli'

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

  it 'does not infer reachability from a node that has no positive witness' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.json')
      head = File.join(directory, 'head.json')
      base_payload = {
        'analysis_health' => { 'status' => 'complete' },
        'findings' => [{
          'classification' => 'unreachable', 'actionability' => 'review_candidate', 'blockers' => [],
          'node' => { 'definition_id' => 'def:dead', 'symbol_id' => 'Service#dead' }
        }],
        'graph' => { 'nodes' => [{ 'definition_id' => 'def:dead' }], 'edges' => [], 'entry_points' => [],
                     'resolutions' => [] }
      }
      head_payload = base_payload.merge('findings' => [])
      File.write(base, JSON.generate(base_payload))
      File.write(head, JSON.generate(head_payload))

      result = described_class.compare_reports(base_path: base, head_path: head)

      expect(result.fetch('newly_reachable')).to eq([])
    end
  end

  it 'accepts an explicit entry point as a reachability witness' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.json')
      head = File.join(directory, 'head.json')
      base_payload = {
        'analysis_health' => { 'status' => 'complete' },
        'findings' => [{
          'classification' => 'unreachable', 'actionability' => 'review_candidate', 'blockers' => [],
          'node' => { 'definition_id' => 'def:dead', 'symbol_id' => 'Service#dead' }
        }],
        'graph' => { 'nodes' => [{ 'definition_id' => 'def:dead' }], 'edges' => [], 'entry_points' => [],
                     'resolutions' => [] }
      }
      head_payload = base_payload.merge(
        'findings' => [],
        'graph' => base_payload['graph'].merge('entry_points' => [{ 'definition_id' => 'def:dead' }])
      )
      File.write(base, JSON.generate(base_payload))
      File.write(head, JSON.generate(head_payload))

      result = described_class.compare_reports(base_path: base, head_path: head)

      expect(result.fetch('newly_reachable')).to include(include('definition_id' => 'def:dead'))
    end
  end

  it 'rejects a non-mapping diff report' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.yml')
      head = File.join(directory, 'head.json')
      File.write(base, "- not-a-report\n")
      File.write(head, JSON.generate('findings' => [], 'graph' => {}))

      expect do
        described_class.compare_reports(base_path: base, head_path: head)
      end.to raise_error(Necropsy::Error, /must contain a mapping/)
    end
  end

  it 'turns malformed diff input into a CLI error without a TypeError trace' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.yml')
      head = File.join(directory, 'head.json')
      File.write(base, "- not-a-report\n")
      File.write(head, JSON.generate('findings' => [], 'graph' => {}))
      status = nil

      expect do
        status = Necropsy::CLI.run(['diff', '--base', base, '--head', head])
      end.to output(/Base diff report must contain a mapping/).to_stderr

      expect(status).to eq(2)
    end
  end

  it 'turns malformed nested diff input into a CLI error' do
    Dir.mktmpdir do |directory|
      base = File.join(directory, 'base.json')
      head = File.join(directory, 'head.json')
      valid = {
        'analysis_health' => { 'status' => 'complete' },
        'findings' => [],
        'graph' => { 'nodes' => [], 'edges' => [], 'entry_points' => [], 'resolutions' => [] }
      }
      File.write(base, JSON.generate(valid))
      File.write(head, JSON.generate(valid.merge('analysis_health' => 'not-a-mapping')))
      status = nil

      expect do
        status = Necropsy::CLI.run(['diff', '--base', base, '--head', head])
      end.to output(/analysis_health must be a mapping/).to_stderr

      expect(status).to eq(2)
    end
  end
end
