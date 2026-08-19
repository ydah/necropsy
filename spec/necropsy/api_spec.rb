# frozen_string_literal: true

RSpec.describe Necropsy do
  it 'analyzes a project through the public API' do
    with_project(files: { 'app/sample.rb' => 'class ApiSample; def dead; end; end' }) do |root|
      report = described_class.analyze(root: root)

      expect(report.findings.map(&:node).map(&:id)).to include('ApiSample#dead')
    end
  end
end
