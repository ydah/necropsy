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
end
