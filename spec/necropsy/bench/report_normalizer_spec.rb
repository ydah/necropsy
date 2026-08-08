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

  it 'separates actionable yield from bounded diagnostic and category metrics' do
    rule_evidence = evidence(metadata: { 'rule_id' => 'registry.literal', 'benchmark_category' => 'registry' })
    candidate = finding(id: 'Measured#dead', classification: :unreachable).with(
      node: node('Measured#dead', line: 4, end_line: 7),
      evidences: [rule_evidence]
    )
    blocker = Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: :message,
      scope_value: 'call',
      source: :spec,
      reason: 'receiver is unknown',
      metadata: {}
    )
    blocked = finding(id: 'Measured#blocked', classification: :blocked, confidence: :low, blockers: [blocker])
    test_only = finding(id: 'Measured#test', classification: :test_only_reachable)
    report = report_with_findings([candidate, blocked, test_only])

    normalized = described_class.new(report: report, corpus: 'measured').call
    findings = normalized.fetch('findings').to_h { |finding| [finding.fetch('id'), finding] }

    expect(normalized.fetch('schema_version')).to eq(1)
    expect(findings.fetch('Measured#dead')).to include(
      'candidate' => true, 'diagnostic' => false, 'loc' => 4, 'category' => 'registry',
      'rule_hits' => ['registry.literal']
    )
    expect(findings.fetch('Measured#blocked')).to include(
      'candidate' => false, 'diagnostic' => true, 'unknown' => true,
      'blocker_kinds' => ['unknown_dispatch']
    )
    expect(normalized.fetch('metrics')).to include(
      'findings' => 3, 'actionable_candidates' => 1, 'candidate_loc' => 4, 'diagnostic_findings' => 2
    )
    expect(normalized.fetch('quality')).to include(
      'candidate_count' => 1, 'candidate_loc' => 4, 'diagnostic_count' => 2,
      'blocked_count' => 1, 'blocked_rate' => 0.3333,
      'unknown_finding_count' => 1, 'unknown_finding_rate' => 0.3333,
      'rule_counts' => { 'registry.literal' => 1 }
    )
    expect(normalized.dig('quality', 'risk_counts')).to include('public_or_protected_visibility' => 3)
  end

  it 'measures only findings inside the configured report scope' do
    included = finding(id: 'Included#dead', file: 'lib/included.rb')
    excluded = finding(id: 'Excluded#dead', file: 'app/excluded.rb')
    included_site = call_site(
      caller_id: included.node.graph_id, message: 'inside', file: 'lib/included.rb', call_site_id: 'call:inside'
    )
    excluded_site = call_site(
      caller_id: excluded.node.graph_id, message: 'outside', file: 'app/excluded.rb', call_site_id: 'call:outside'
    )
    graph = graph_with(nodes: [included.node, excluded.node], call_sites: [included_site, excluded_site])
    [included_site, excluded_site].each do |site|
      resolution = Necropsy::Resolution.new(
        call_site_id: site.call_site_id, target_definition_ids: [], status: :complete
      )
      graph.apply_result(analyzer_result(resolutions: [
                                           Necropsy::ResolutionRecord.new(
                                             resolution: resolution, producer: :spec, producer_version: '1'
                                           )
                                         ]))
    end
    graph.add_entry_point(excluded.node.graph_id, :rails_route)
    report = Necropsy::Report.new(
      root: '/repo',
      graph: graph,
      findings: [included, excluded],
      report_include_paths: ['lib/**']
    )

    normalized = described_class.new(report: report, corpus: 'scoped').call

    expect(normalized.fetch('findings').map { |finding| finding.fetch('id') }).to eq(['Included#dead'])
    expect(normalized.fetch('metrics')).to include('findings' => 1, 'actionable_candidates' => 1)
    expect(normalized.dig('metrics', 'analysis_graph')).to include('scope' => 'analysis', 'call_sites' => 2)
    expect(normalized.fetch('quality')).to include(
      'scope' => 'report', 'candidate_count' => 1, 'candidate_loc' => 1,
      'resolution_counts' => { 'total' => 1, 'complete' => 1, 'partial' => 0, 'unknown' => 0 },
      'rule_counts' => {}
    )
  end

  it 'counts unsupported semantic lookup as unknown diagnostics' do
    blocker = Necropsy::Blocker.new(
      kind: :unsupported_refinement,
      scope_kind: :owner,
      scope_value: 'Refined',
      source: :spec,
      reason: 'lexical lookup is not modeled',
      metadata: {}
    )
    finding = finding(id: 'Refined#call', classification: :blocked, confidence: :low, blockers: [blocker])

    normalized = described_class.new(report: report_with_findings([finding]), corpus: 'semantic').call

    expect(normalized.dig('findings', 0)).to include('candidate' => false, 'unknown' => true)
    expect(normalized.fetch('quality')).to include(
      'blocked_rate' => 1.0, 'unknown_finding_count' => 1, 'unknown_finding_rate' => 1.0
    )
  end
end
