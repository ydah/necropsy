# frozen_string_literal: true

RSpec.describe Necropsy do
  it 'exposes default analyzers in the documented order' do
    expect(described_class.default_analyzers.map { |analyzer| analyzer.profile.name }).to eq(
      %i[name_resolution cha rta]
    )
  end

  it 'analyzes a project through the public API' do
    with_project(files: { 'app/sample.rb' => 'class ApiSample; def dead; end; end' }) do |root|
      report = described_class.analyze(root: root)

      expect(report.findings.map(&:node).map(&:id)).to include('ApiSample#dead')
    end
  end
end
