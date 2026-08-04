# frozen_string_literal: true

require 'necropsy/bench/seed_runner'
require 'stringio'

RSpec.describe Necropsy::Bench::SeedRunner do
  it 'explicitly skips unavailable corpora and comparison tools' do
    with_project(files: {
                   'labels.yml' => { 'schema_version' => 1, 'labels' => [] }.to_yaml,
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => {
                       'external' => { 'path_env' => 'NECROPSY_MISSING_CORPUS', 'revision' => 'pinned' }
                     },
                     'tools' => {
                       'necropsy' => { 'version' => 'test' },
                       'missing_tool' => { 'command' => ['definitely-not-a-necropsy-tool'], 'version' => 'pinned' }
                     }
                   }.to_yaml
                 }) do |root|
      output = File.join(root, 'output')
      io = StringIO.new
      result = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: output,
        io: io
      ).call

      expect(result.fetch('corpora').first).to include('status' => 'skipped')
      expect(result.fetch('diagnostics')).to include(
        match(/external skipped: corpus unavailable/),
        match(/missing_tool skipped: .*executable.*not found/)
      )
      expect(io.string).to include('external skipped')
      expect(JSON.parse(File.read(File.join(output, 'summary.json')))).to eq(result)
    end
  end

  it 'requires an audit reason before replacing golden files' do
    with_project(files: {
                   'labels.yml' => { 'labels' => [] }.to_yaml,
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => {},
                     'tools' => { 'necropsy' => {} }
                   }.to_yaml
                 }) do |root|
      runner = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: File.join(root, 'output'),
        io: StringIO.new
      )

      expect { runner.call(update_golden_reason: '  ') }.to raise_error(
        Necropsy::Error, /requires a non-empty reason/
      )
    end
  end
end
