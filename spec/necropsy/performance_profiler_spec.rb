# frozen_string_literal: true

RSpec.describe Necropsy::PerformanceProfiler do
  it 'records deterministic phase timing, allocations, RSS, and counts' do
    clock_values = [1.0, 1.25, 2.0, 2.5]
    allocations = [10, 15, 20, 24]
    rss = [100, 120, 115, 140]
    clock = ->(*) { clock_values.shift }
    allocation_reader = -> { allocations.shift }
    rss_reader = -> { rss.shift }
    profiler = described_class.new(clock: clock, allocation_reader: allocation_reader, rss_reader: rss_reader)

    profiler.measure('scan') { :scan }
    profiler.measure('resolve') { :resolve }
    report = profiler.report(counts: { definitions: 3, edges: 2 }, report_index_size_bytes: 512)

    expect(report).to include(
      'schema_version' => 1,
      'memory' => include('peak_rss_kb' => 140, 'rss_status' => 'available'),
      'counts' => { 'definitions' => 3, 'edges' => 2 },
      'report_index_size_bytes' => 512
    )
    expect(report.fetch('phases')).to include(
      include('name' => 'scan', 'wall_time_seconds' => 0.25, 'allocated_objects' => 5),
      include('name' => 'resolve', 'wall_time_seconds' => 0.5, 'allocated_objects' => 4)
    )
  end

  it 'exposes an opt-in profile on analysis reports' do
    report = Necropsy.analyze(root: fixture_path('sample_project'), profile: true)

    expect(report.performance_profile).to include(
      'schema_version' => 1,
      'counts' => include('definitions', 'call_sites', 'edges', 'blockers')
    )
    expect(report.to_h.fetch('diagnostics')).to include('performance' => report.performance_profile)
  end
end
