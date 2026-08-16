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

  it 'rejects a static report without a target source' do
    Dir.mktmpdir do |directory|
      static_path = File.join(directory, 'static.json')
      observed_path = File.join(directory, 'observed.json')
      File.write(static_path, JSON.generate('findings' => []))
      File.write(observed_path, JSON.generate([]))

      expect do
        described_class.new(static_report: static_path, observed_artifact: observed_path)
      end.to raise_error(Necropsy::Error, /static_targets or graph\.resolutions/)
    end
  end

  it 'rejects a non-mapping static artifact before field access' do
    Dir.mktmpdir do |directory|
      static_path = File.join(directory, 'static.yml')
      observed_path = File.join(directory, 'observed.json')
      File.write(static_path, "- not-a-report\n")
      File.write(observed_path, JSON.generate([]))

      expect do
        described_class.new(static_report: static_path, observed_artifact: observed_path)
      end.to raise_error(Necropsy::Error, /must contain a mapping/)
    end
  end

  it 'rejects non-scalar observed identifiers at the artifact boundary' do
    Dir.mktmpdir do |directory|
      static_path = File.join(directory, 'static.json')
      observed_path = File.join(directory, 'observed.json')
      File.write(static_path, JSON.generate('graph' => {
                                              'resolutions' => [{ 'resolution' => {
                                                'call_site_id' => 'call:one', 'target_definition_ids' => ['Service#run']
                                              } }]
                                            }))
      File.write(observed_path, JSON.generate('observed_targets' => [
                                                { 'call_site_id' => [], 'target_definition_id' => 'Service#run' }
                                              ]))

      expect do
        described_class.new(static_report: static_path, observed_artifact: observed_path)
      end.to raise_error(Necropsy::Error, /must include call_site_id/)
    end
  end

  it 'rejects non-scalar static identifiers at the artifact boundary' do
    Dir.mktmpdir do |directory|
      static_path = File.join(directory, 'static.json')
      observed_path = File.join(directory, 'observed.json')
      File.write(static_path, JSON.generate('static_targets' => { 'call:one' => [{}] }))
      File.write(observed_path, JSON.generate([]))

      expect do
        described_class.new(static_report: static_path, observed_artifact: observed_path)
      end.to raise_error(Necropsy::Error, /scalar non-empty IDs/)
    end
  end
end
