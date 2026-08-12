# frozen_string_literal: true

require 'necropsy/bench/safety_mutation_harness'

RSpec.describe Necropsy::Bench::SafetyMutationHarness do
  def rebuild(report, findings:, health: report.analysis_health)
    Necropsy::Report.new(
      root: report.root,
      graph: report.graph,
      findings: findings,
      reachability: report.reachability,
      project: report.project,
      source_snapshot: report.source_snapshot,
      performance_profile: report.performance_profile,
      analysis_health: health
    )
  end

  it 'kills mutations that remove blockers or promote incomplete health' do
    files = {
      'lib/target.rb' => 'class MutationTarget; def referenced; end; end',
      'config/reference.yml' => "handler: referenced\n",
      'lib/broken.rb' => "class Broken\n  def unfinished(\nend\n"
    }
    config = { cache: { enabled: false }, paths: { analyze: ['lib/**'], reference: ['**/*'] } }

    with_project(files: files, config: config) do |root|
      baseline = Necropsy::Runner.new(root: root).analyze
      blocked = baseline.findings.find { |finding| finding.node.symbol_id == 'MutationTarget#referenced' }
      bypass = blocked.with(classification: :unreachable, blockers: [])
      without_blocker = rebuild(baseline, findings: baseline.findings.map { |finding| finding == blocked ? bypass : finding })
      promoted_health = Necropsy::AnalysisHealth.new(status: :complete, reasons: [])
      without_health_gate = rebuild(baseline, findings: baseline.findings, health: promoted_health)

      results = described_class.new(baseline: baseline).assert_all_detected!(
        blocker_removed: without_blocker,
        health_gate_removed: without_health_gate
      )
      expect(results.values).to all(have_attributes(detected: true))
      expect(results.values.map(&:violations)).to all(be_an(Array).and(satisfy(&:any?)))
    end
  end

  it 'rejects an unknown-scope mutation at the model boundary' do
    expect do
      Necropsy::Resolution.new(
        call_site_id: 'site', target_definition_ids: [], status: :complete,
        unknown_scope: Necropsy::UnknownScope.new(scope_kind: :global, scope_value: '*', match: :glob)
      )
    end.to raise_error(ArgumentError, /complete resolution must not have an unknown scope/)
  end
end
