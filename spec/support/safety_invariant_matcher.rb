# frozen_string_literal: true

module SafetyInvariantMatcher
  module_function

  def candidate_ids(report, min_confidence: :low)
    report.findings.select do |finding|
      finding.classification != :blocked && finding.at_least?(min_confidence)
    end.to_set { |finding| finding.node.id }
  end
end

RSpec::Matchers.define :preserve_candidate_safety_from do |before_report|
  chain :for_invariant do |invariant|
    @invariant = invariant
  end

  chain :with_equal_sets do
    @require_equal_sets = true
  end

  match do |after_report|
    @before_candidates = SafetyInvariantMatcher.candidate_ids(before_report)
    @after_candidates = SafetyInvariantMatcher.candidate_ids(after_report)
    @before_high = SafetyInvariantMatcher.candidate_ids(before_report, min_confidence: :high)
    @after_high = SafetyInvariantMatcher.candidate_ids(after_report, min_confidence: :high)
    @added_candidates = @after_candidates - @before_candidates
    @added_high = @after_high - @before_high
    @removed_candidates = @before_candidates - @after_candidates
    @removed_high = @before_high - @after_high

    @added_candidates.empty? && @added_high.empty? && equal_sets_if_required?
  end

  failure_message do
    <<~MESSAGE.chomp
      Safety invariant #{@invariant.inspect} failed.
      Added candidates: #{@added_candidates.to_a.sort.inspect}
      Added high candidates: #{@added_high.to_a.sort.inspect}
      Removed candidates: #{@removed_candidates.to_a.sort.inspect}
      Removed high candidates: #{@removed_high.to_a.sort.inspect}
      Before candidates/high: #{@before_candidates.size}/#{@before_high.size}
      After candidates/high: #{@after_candidates.size}/#{@after_high.size}
    MESSAGE
  end

  def equal_sets_if_required?
    !@require_equal_sets || (@removed_candidates.empty? && @removed_high.empty?)
  end
end
