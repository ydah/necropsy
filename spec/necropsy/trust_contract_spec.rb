# frozen_string_literal: true

RSpec.describe 'Necropsy trust contract' do
  it 'keeps actionability independent from priority confidence' do
    candidate = finding(classification: :unreachable, confidence: :medium, score: 0.62)
    report = report_with_findings([candidate])

    expect(candidate).to have_attributes(
      reachability_state: :unreachable_under_model,
      analysis_completeness: :complete,
      actionability: :review_candidate
    )
    expect(report.actionable_candidates(min_actionability: :review_candidate)).to eq([candidate])
    expect(report.actionable_candidates(min_actionability: :verified_candidate)).to eq([])
  end

  it 'makes blockers dominate actionability regardless of score' do
    blocker = Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: :message,
      scope_value: 'run',
      source: :spec,
      reason: 'receiver is unknown'
    )
    blocked = finding(classification: :blocked, confidence: :certain, score: 1.0, blockers: [blocker])

    expect(blocked).to have_attributes(
      reachability_state: :unknown,
      analysis_completeness: :partial,
      actionability: :diagnostic
    )
    expect(report_with_findings([blocked]).actionable_candidates(min_confidence: :low)).to eq([])
  end

  it 'rejects an explicitly actionable incomplete finding at the model boundary' do
    expect do
      Necropsy::Finding.new(
        node: node('Sample#dead'),
        classification: :unreachable,
        confidence: :high,
        score: 0.8,
        score_components: [],
        reasons: [],
        evidences: [],
        blockers: [instance_double(Necropsy::Blocker)],
        actionability: :review_candidate,
        analysis_completeness: :partial
      )
    end.to raise_error(ArgumentError, /incomplete findings cannot be actionable/)
  end
end
