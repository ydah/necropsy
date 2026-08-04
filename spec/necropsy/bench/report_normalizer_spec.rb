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
      cached = normalized(root)
      write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)

      expect(normalized(root)).to eq(cached)
    end
  end
end
