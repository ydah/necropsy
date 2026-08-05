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
      first = cache.fetch(project.ruby_files) { scan_result(nodes: [definition]) }
      second = described_class.new(project: project).fetch(project.ruby_files) { raise 'cache miss' }
      payload = JSON.parse(File.read(File.join(root, '.necropsy_cache/scan.json')))

      expect(second).to eq(first)
      expect(second.nodes.first).to have_attributes(
        symbol_id: 'CachedDefinition#run', definition_id: 'def:v1:physical',
        body_digest: 'body-digest', ordinal: 2
      )
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
