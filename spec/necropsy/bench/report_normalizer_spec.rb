# frozen_string_literal: true

require 'necropsy/bench/report_normalizer'

RSpec.describe Necropsy::Bench::ReportNormalizer do
  def normalized(root, corpus: 'fixture')
    described_class.new(report: Necropsy.analyze(root: root), corpus: corpus).dump
  end

  it 'produces byte-identical output for repeated analysis' do
    root = fixture_path('benchmark/plain_ruby')

    expect(normalized(root)).to eq(normalized(root))
  end

  it 'is independent of file discovery order' do
    with_project(
      config: { cache: { enabled: false } },
      files: {
        'lib/order.rb' => "class OrderSeed; def run; helper; end; def helper; end; end\n",
        'bin/run' => "#!/usr/bin/env ruby\nOrderSeed.new.run\n"
      }
    ) do |root|
      ordered = normalized(root)
      reversed_glob = receive(:glob).and_wrap_original { |method, *args| method.call(*args).reverse }
      allow(Dir).to reversed_glob

      expect(normalized(root)).to eq(ordered)
    end
  end

  it 'is identical with the scan cache enabled and disabled' do
    with_project(
      config: { cache: { enabled: true } },
      files: {
        'lib/cache_seed.rb' => "class CacheSeed; def live; end; def dead; end; end\n",
        'bin/run' => "#!/usr/bin/env ruby\nCacheSeed.new.live\n"
      }
    ) do |root|
      scans = 0
      scanner = receive(:scan).and_wrap_original do |method, *args|
        scans += 1
        method.call(*args)
      end
      allow_any_instance_of(Necropsy::AstScanner).to scanner

      cold_cache = normalized(root)
      warm_cache = normalized(root)
      expect(scans).to eq(1)

      write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)
      cache_disabled = normalized(root)

      expect(scans).to eq(2)
      expect(warm_cache).to eq(cold_cache)
      expect(cache_disabled).to eq(cold_cache)
    end
  end

  it 'retains a method backed by positive dynamic evidence' do
    report = Necropsy.analyze(root: fixture_path('benchmark/dynamic_evidence'))
    normalized = described_class.new(report: report, corpus: 'dynamic_evidence').call

    expect(report.graph).to be_dynamic_alive('DynamicSeed#observed_only')
    expect(normalized.fetch('findings').map { |finding| finding.fetch('id') }).not_to include(
      'DynamicSeed#observed_only'
    )
  end
end
