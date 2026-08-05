# frozen_string_literal: true

RSpec.describe Necropsy::Cache::ScanCache do
  it 'stores and reloads scan results when metadata matches' do
    source = 'class CachedSample; def run; helper; end; def helper; end; end'
    with_project(files: { 'app/sample.rb' => source }) do |root|
      project = project_for(root)
      cache = described_class.new(project: project)
      calls = 0

      first = cache.fetch(project.ruby_files) do
        calls += 1
        Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
      end
      second = described_class.new(project: project).fetch(project.ruby_files) do
        calls += 1
        raise 'cache miss'
      end

      expect(calls).to eq(1)
      expect(second.nodes.map(&:id)).to eq(first.nodes.map(&:id))
      expect(second.call_sites.map(&:to_h)).to eq(first.call_sites.map(&:to_h))
      expect(second.call_sites.map(&:call_site_id)).to all(match(/\Acall:v1:[0-9a-f]{64}\z/))
      expect(second.file_statuses).to eq(first.file_statuses)
      expect(second.source_errors).to eq(first.source_errors)
      payload = JSON.parse(File.read(File.join(root, '.necropsy_cache/scan.json')))
      expect(payload).to include('version' => described_class::VERSION)
      expect(payload.dig('scan_result', 'call_sites', 0)).to include(
        'call_site_id' => first.call_sites.first.call_site_id,
        'caller_definition_id' => first.call_sites.first.caller_definition_id
      )
    end
  end

  it 'invalidates the cache when configuration changes' do
    with_project(files: { 'app/sample.rb' => 'class CacheFactory; end; CacheFactory.spawn' }) do |root|
      first = scan_project(root)
      write_project_file(root, '.necropsy.yml', { rta: { factory_methods: ['spawn'] } }.to_yaml)
      second = scan_project(root)

      expect(first.instantiated_classes).not_to include('CacheFactory')
      expect(second.instantiated_classes).to include('CacheFactory')
    end
  end

  it 'invalidates the project scan when a non-Ruby reference file changes' do
    config = { paths: { analyze: ['lib/**'], reference: ['**/*'] } }
    with_project(
      files: { 'lib/sample.rb' => 'class ReferenceCache; end', 'config/jobs.yml' => "job: one\n" },
      config: config
    ) do |root|
      calls = 0
      first_project = project_for(root)
      first = described_class.new(project: first_project).fetch(first_project.cache_files) do
        calls += 1
        scan_result(nodes: [], scope_diagnostics: { 'revision' => 'first' })
      end
      write_project_file(root, 'config/jobs.yml', "job: a-longer-value\n")
      second_project = project_for(root)
      second = described_class.new(project: second_project).fetch(second_project.cache_files) do
        calls += 1
        scan_result(nodes: [], scope_diagnostics: { 'revision' => 'second' })
      end

      expect(calls).to eq(2)
      expect(first.scope_diagnostics).to eq('revision' => 'first')
      expect(second.scope_diagnostics).to eq('revision' => 'second')
    end
  end

  it 'excludes a custom cache output from repository reference metadata' do
    config = { cache: { path: 'cache/scan.json' } }
    with_project(files: { 'lib/sample.rb' => 'class CustomCache; end' }, config: config) do |root|
      first = project_for(root).scan_result
      second_project = project_for(root)

      expect(second_project.reference_files).not_to include(File.join(root, 'cache/scan.json'))
      expect(Necropsy::AstScanner).not_to receive(:new)
      expect(second_project.scan_result).to eq(first)
    end
  end

  it 'invalidates cached scope diagnostics when an ignored symlink is added or removed' do
    Dir.mktmpdir do |outside|
      outside_source = File.join(outside, 'external.rb')
      File.write(outside_source, 'class External; end')
      with_project(files: { 'lib/sample.rb' => 'class SymlinkCache; end' }) do |root|
        first = project_for(root).scan_result
        link = File.join(root, 'external.rb')
        File.symlink(outside_source, link)
        second = project_for(root).scan_result
        File.unlink(link)
        third = project_for(root).scan_result

        expect(first.scope_diagnostics.fetch('ignored_symlinks')).to eq([])
        expect(second.scope_diagnostics.fetch('ignored_symlinks')).to eq(['external.rb'])
        expect(third.scope_diagnostics.fetch('ignored_symlinks')).to eq([])
      end
    end
  end

  it 'invalidates cached scope diagnostics when Ruby files appear outside both scopes' do
    config = { paths: { analyze: ['lib/**'], reference: ['lib/**'] } }
    with_project(files: { 'lib/sample.rb' => 'class ScopedCache; end' }, config: config) do |root|
      first = project_for(root).scan_result
      write_project_file(root, 'app/caller.rb', 'ScopedCache.new')
      second = nil
      expect { second = project_for(root).scan_result }.to output(
        /paths.reference excludes Ruby files that may contain runtime callers/
      ).to_stderr

      expect(first.scope_diagnostics.dig('potential_callers_outside_reference', 'count')).to eq(0)
      expect(second.scope_diagnostics.dig('potential_callers_outside_reference', 'samples')).to eq(
        ['app/caller.rb']
      )
    end
  end

  it 'round-trips the full scan result including symbolic source error types' do
    source = "class CachedRecovery\n  def retained; end\n  def broken(\nend\n"

    with_project(files: { 'app/recovered.rb' => source }) do |root|
      project = project_for(root)
      first = described_class.new(project: project).fetch(project.ruby_files) do
        Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
      end
      second = described_class.new(project: project).fetch(project.ruby_files) do
        raise 'cache miss'
      end

      expect(first.source_errors.first.type).to be_a(Symbol)
      expect(second).to eq(first)
    end
  end

  it 'round-trips physical definition identity fields' do
    with_project(files: { 'app/sample.rb' => 'class CachedDefinition; end' }) do |root|
      project = project_for(root)
      cache = described_class.new(project: project)
      definition = node(
        'CachedDefinition#run',
        file: 'app/sample.rb',
        definition_id: 'def:v1:physical',
        body_digest: 'body-digest', ordinal: 2
      )
      first = cache.fetch(project.ruby_files) do
        scan_result(
          nodes: [definition],
          source_domains: { 'app/sample.rb' => :reference },
          scope_diagnostics: { 'reference_only_ruby_files' => ['app/sample.rb'] }
        )
      end
      second = described_class.new(project: project).fetch(project.ruby_files) { raise 'cache miss' }
      payload = JSON.parse(File.read(File.join(root, '.necropsy_cache/scan.json')))

      expect(second).to eq(first)
      expect(second.nodes.first).to have_attributes(
        symbol_id: 'CachedDefinition#run', definition_id: 'def:v1:physical',
        body_digest: 'body-digest', ordinal: 2
      )
      expect(second.source_domains).to eq('app/sample.rb' => :reference)
      expect(second.scope_diagnostics).to eq('reference_only_ruby_files' => ['app/sample.rb'])
      expect(payload.dig('scan_result', 'nodes', 0)).to include(
        'id' => 'CachedDefinition#run',
        'symbol_id' => 'CachedDefinition#run',
        'definition_id' => 'def:v1:physical',
        'body_digest' => 'body-digest',
        'ordinal' => 2
      )
    end
  end

  it 'falls back to a fresh scan when a legacy cache version is present' do
    with_project(files: { 'app/sample.rb' => 'class LegacyCache; def run = helper; def helper; end; end' }) do |root|
      project = project_for(root)
      cache_path = File.join(root, '.necropsy_cache/scan.json')
      calls = 0
      scan = lambda do
        calls += 1
        Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
      end

      described_class.new(project: project).fetch(project.ruby_files, &scan)
      payload = JSON.parse(File.read(cache_path))
      payload.fetch('scan_result').fetch('call_sites').first['call_site_id'] = 'call:v1:legacy-canonicalizer'
      File.write(cache_path, JSON.generate(payload.merge('version' => described_class::VERSION - 1)))
      result = described_class.new(project: project).fetch(project.ruby_files, &scan)

      expect(calls).to eq(2)
      expect(result.file_statuses).to eq('app/sample.rb' => :complete)
      expect(result.call_sites.first.call_site_id).not_to eq('call:v1:legacy-canonicalizer')
      rewritten = JSON.parse(File.read(cache_path))
      expect(rewritten.fetch('version')).to eq(described_class::VERSION)
      expect(rewritten.dig('scan_result', 'call_sites', 0, 'call_site_id')).to eq(
        result.call_sites.first.call_site_id
      )
    end
  end
end
