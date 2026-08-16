# frozen_string_literal: true

RSpec.describe Necropsy::FeedbackWorkflow do
  it 'compares artifacts, exports bounded fixtures, and verifies missing targets' do
    Dir.mktmpdir do |directory|
      static_path = File.join(directory, 'static.json')
      observed_path = File.join(directory, 'observed.json')
      output_path = File.join(directory, 'fixtures.json')
      File.write(static_path, JSON.generate('graph' => {
                                              'resolutions' => [{ 'resolution' => {
                                                'call_site_id' => 'call:one', 'target_definition_ids' => ['Service#run']
                                              } }]
                                            }))
      File.write(observed_path, JSON.generate('observed_targets' => [
                                                { 'call_site_id' => 'call:one', 'target_definition_id' => 'Service#run' },
                                                { 'call_site_id' => 'call:one', 'target_definition_id' => 'Missing#run' }
                                              ]))

      workflow = described_class.new(static_report: static_path, observed_artifact: observed_path)
      comparison = workflow.compare
      exported = workflow.export_fixtures(output_path)
      verification = workflow.verify(fail_on_missing_static_target: true)

      expect(comparison.fetch('missing_static_targets').map { |target| target['target_definition_id'] }).to eq(
        ['Missing#run']
      )
      expect(exported).to include('fixture_exported' => true, 'fixture_path' => output_path)
      expect(verification.dig('verification', 'passed')).to be(false)
      expect(JSON.parse(File.read(output_path))).to all(include('target_definition_id' => 'Missing#run'))
    end
  end
end
