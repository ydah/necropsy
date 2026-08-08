# frozen_string_literal: true

RSpec.describe Necropsy::RuntimeFeedback do
  let(:static_targets) do
    {
      'call:one' => ['Service#run', 'Fallback#run'],
      'call:two' => ['Other#run']
    }
  end

  it 'reports observed targets missing from static resolution and preserves unobserved targets' do
    result = described_class.new(
      static_targets: static_targets,
      observed_targets: [
        { call_site_id: 'call:one', target_definition_id: 'Service#run', receiver_class: 'Service' },
        { call_site_id: 'call:one', target_definition_id: 'Unexpected#run', receiver_class: 'Unexpected' }
      ]
    ).call

    expect(result.fetch('missing_static_targets')).to eq(
      [{
        'call_site_id' => 'call:one',
        'target_definition_id' => 'Unexpected#run',
        'receiver_class' => 'Unexpected',
        'classification' => 'missing_static_target',
        'safety' => 'safety_bug'
      }]
    )
    expect(result.fetch('unobserved_static_targets')).to include(
      'call_site_id' => 'call:one', 'target_definition_id' => 'Fallback#run', 'informational' => true
    )
    expect(result.fetch('fixture_candidates').first).to include(
      'call_site_id' => 'call:one', 'target_definition_id' => 'Unexpected#run'
    )
  end

  it 'exports bounded fixture candidates atomically' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'feedback.json')
      feedback = described_class.new(
        static_targets: {},
        observed_targets: [{ call_site_id: 'call:one', target_definition_id: 'Service#run' }],
        max_fixtures: 1
      )

      result = feedback.write_fixture_candidates(path)

      expect(result).to include('fixture_exported' => true, 'fixture_path' => path)
      expect(JSON.parse(File.read(path))).to include(
        include('call_site_id' => 'call:one', 'target_definition_id' => 'Service#run')
      )
      expect(Dir.glob("#{path}.tmp-*")).to be_empty
    end
  end

  it 'rejects malformed observations' do
    expect do
      described_class.new(static_targets: {}, observed_targets: [{ call_site_id: 'call:one' }])
    end.to raise_error(ArgumentError, /target_definition_id/)
  end
end
