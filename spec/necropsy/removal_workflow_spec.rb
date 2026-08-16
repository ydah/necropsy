# frozen_string_literal: true

RSpec.describe Necropsy::RemovalWorkflow do
  it 'previews a physical method removal and verifies it in an isolated copy' do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'lib'))
      source_path = File.join(root, 'lib/sample.rb')
      File.write(source_path, "class Sample\n  def dead\n    :dead\n  end\nend\n")
      report_path = File.join(root, 'report.json')
      File.write(report_path, JSON.generate(
                                'analysis_health' => { 'status' => 'complete' },
                                'findings' => [{
                                  'classification' => 'unreachable', 'actionability' => 'review_candidate', 'blockers' => [],
                                  'node' => {
                                    'definition_id' => 'def:dead', 'symbol_id' => 'Sample#dead', 'file' => 'lib/sample.rb',
                                    'line' => 2, 'end_line' => 4, 'visibility' => 'private'
                                  }
                                }]
                              ))

      workflow = described_class.new(report_path: report_path, candidate: 'def:dead', root: root)
      patch = workflow.patch_preview
      result = workflow.verify([RbConfig.ruby, '-e', 'exit(!File.read("lib/sample.rb").include?("dead"))'])

      expect(patch).to include('--- a/lib/sample.rb', '-  def dead', '-  end')
      expect(result).to include('passed' => true)
      expect(File.read(source_path)).to include('def dead')
    end
  end

  it 'returns a failed bounded result when verification exceeds its timeout' do
    Dir.mktmpdir do |root|
      source_path = File.join(root, 'sample.rb')
      File.write(source_path, "class Sample\n  def dead\n    :dead\n  end\nend\n")
      report_path = File.join(root, 'report.json')
      File.write(report_path, JSON.generate(
                                'findings' => [{
                                  'classification' => 'unreachable', 'actionability' => 'review_candidate', 'blockers' => [],
                                  'node' => {
                                    'definition_id' => 'def:dead', 'symbol_id' => 'Sample#dead', 'file' => 'sample.rb',
                                    'line' => 2, 'end_line' => 4
                                  }
                                }]
                              ))

      workflow = described_class.new(report_path: report_path, candidate: 'def:dead', root: root,
                                     timeout_seconds: 0.05)
      result = workflow.verify([RbConfig.ruby, '-e', 'sleep 2'])

      expect(result).to include('passed' => false, 'timed_out' => true, 'status' => nil)
    end
  end

  it 'rejects a non-mapping removal report' do
    Dir.mktmpdir do |root|
      report_path = File.join(root, 'report.yml')
      File.write(report_path, "- not-a-report\n")

      expect do
        described_class.new(report_path: report_path, candidate: 'def:dead', root: root)
      end.to raise_error(Necropsy::Error, /must contain a mapping/)
    end
  end
end
