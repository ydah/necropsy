# frozen_string_literal: true

require 'necropsy/bench/seed_runner'
require 'open3'
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

  it 'fails a pinned Git corpus whose HEAD does not match the manifest' do
    with_project(files: {
                   'labels.yml' => { 'labels' => [] }.to_yaml,
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => { 'pinned' => { 'path' => '.', 'git_commit' => 'expected' } },
                     'tools' => { 'necropsy' => {} }
                   }.to_yaml
                 }) do |root|
      result = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: File.join(root, 'output'),
        io: StringIO.new,
        analyzer: ->(*) { raise 'analysis must not run' },
        revision_reader: ->(*) { 'different' }
      ).call

      expect(result.fetch('corpora').first).to include('status' => 'failed')
      expect(result.fetch('diagnostics')).to include(match(/expected Git HEAD expected, got different/))
    end
  end

  it 'fails a pinned Git corpus with tracked working-tree changes' do
    with_project(files: {
                   'labels.yml' => { 'labels' => [] }.to_yaml,
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => { 'pinned' => { 'path' => '.', 'git_commit' => 'expected' } },
                     'tools' => { 'necropsy' => {} }
                   }.to_yaml
                 }) do |root|
      result = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: File.join(root, 'output'),
        io: StringIO.new,
        analyzer: ->(*) { raise 'analysis must not run' },
        revision_reader: ->(*) { 'expected' },
        dirty_reader: ->(*) { true }
      ).call

      expect(result.fetch('corpora').first).to include('status' => 'failed')
      expect(result.fetch('diagnostics')).to include(match(/tracked Git changes present/))
    end
  end

  it 'preserves existing golden files when a required corpus was not generated' do
    with_project(files: {
                   'labels.yml' => { 'labels' => [] }.to_yaml,
                   'golden/candidate_union.json' => "existing golden\n",
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => {
                       'external' => { 'required' => true, 'path_env' => 'NECROPSY_REQUIRED_MISSING' }
                     },
                     'tools' => { 'necropsy' => {} }
                   }.to_yaml
                 }) do |root|
      runner = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: File.join(root, 'output'),
        io: StringIO.new
      )

      expect do
        runner.call(update_golden_reason: 'must not apply')
      end.to raise_error(Necropsy::Error, /required corpora were not generated: external/)
      expect(File.read(File.join(root, 'golden/candidate_union.json'))).to eq("existing golden\n")
    end
  end

  it 'reports unavailable RSS without presenting it as a peak measurement' do
    with_project(files: {
                   'labels.yml' => { 'labels' => [] }.to_yaml,
                   'lib/sample.rb' => "class RssSeed; def dead; end; end\n",
                   'manifest.yml' => {
                     'schema_version' => 1,
                     'repository_root' => '.',
                     'golden_dir' => 'golden',
                     'labels' => 'labels.yml',
                     'minimum_reviewed_labels' => 0,
                     'corpora' => { 'fixture' => { 'path' => '.' } },
                     'tools' => { 'necropsy' => {} }
                   }.to_yaml
                 }) do |root|
      result = described_class.new(
        manifest_path: File.join(root, 'manifest.yml'),
        output_dir: File.join(root, 'output'),
        io: StringIO.new,
        rss_reader: -> {}
      ).call
      performance = result.fetch('corpora').first.fetch('performance')

      expect(performance).to include('rss_status' => 'unavailable')
      expect(performance).not_to have_key('peak_rss_kb')
      expect(result.fetch('diagnostics')).to include(match(/RSS unavailable/))
    end
  end

  it 'binds golden updates to a reason and artifact digests' do
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
      updated = runner.call(update_golden_reason: 'reviewed drift')
      expect(updated.dig('golden', 'status')).to eq('match')

      golden = File.join(root, 'golden/candidate_union.json')
      File.write(golden, "#{File.read(golden)} ")
      drifted = runner.call

      expect(drifted.dig('golden', 'status')).to eq('invalid')
      expect(drifted.dig('golden', 'differences')).to include('candidate_union.json')
    end
  end

  it 'exits nonzero and displays status when golden output is missing' do
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
      command = [RbConfig.ruby, File.expand_path('../../../bench/run.rb', __dir__), '--manifest',
                 File.join(root, 'manifest.yml'), '--output', File.join(root, 'output')]
      stdout, _stderr, status = Open3.capture3(*command)

      expect(status).not_to be_success
      expect(stdout).to include('golden: missing')
    end
  end
end
