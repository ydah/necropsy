# frozen_string_literal: true

RSpec.describe 'repository self scan' do
  it 'scans deterministically without identity serialization failures' do
    root = File.expand_path('../..', __dir__)
    config = Necropsy::Configuration.new(
      root: root,
      path: File.join(root, '.necropsy.yml'),
      data: { cache: { enabled: false } }
    )
    project = Necropsy::Project.new(root: root, config: config)
    first = Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
    second = Necropsy::AstScanner.new(project: project, files: project.ruby_files.reverse).scan

    expect(first.file_statuses.values).to all(eq(:complete))
    expect(first.nodes.map(&:graph_id)).to eq(second.nodes.map(&:graph_id))
    expect(first.nodes.map(&:definition_id)).to all(match(/\Adef:v1:[0-9a-f]{64}\z/))
  end
end
