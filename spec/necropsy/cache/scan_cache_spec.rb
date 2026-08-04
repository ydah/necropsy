# frozen_string_literal: true

RSpec.describe Necropsy::Cache::ScanCache do
  it 'stores and reloads scan results when metadata matches' do
    with_project(files: { 'app/sample.rb' => 'class CachedSample; def run; end; end' }) do |root|
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
      expect(second.file_statuses).to eq(first.file_statuses)
      expect(second.source_errors).to eq(first.source_errors)
      expect(JSON.parse(File.read(File.join(root, '.necropsy_cache/scan.json')))).to include('version')
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

  it 'falls back to a fresh scan when a legacy cache version is present' do
    with_project(files: { 'app/sample.rb' => 'class LegacyCache; def run; end; end' }) do |root|
      project = project_for(root)
      cache_path = File.join(root, '.necropsy_cache/scan.json')
      calls = 0
      scan = lambda do
        calls += 1
        Necropsy::AstScanner.new(project: project, files: project.ruby_files).scan
      end

      described_class.new(project: project).fetch(project.ruby_files, &scan)
      payload = JSON.parse(File.read(cache_path))
      File.write(cache_path, JSON.generate(payload.merge('version' => described_class::VERSION - 1)))
      result = described_class.new(project: project).fetch(project.ruby_files, &scan)

      expect(calls).to eq(2)
      expect(result.file_statuses).to eq('app/sample.rb' => :complete)
      expect(JSON.parse(File.read(cache_path)).fetch('version')).to eq(described_class::VERSION)
    end
  end
end
