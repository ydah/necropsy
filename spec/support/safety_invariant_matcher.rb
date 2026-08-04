# frozen_string_literal: true

module SafetyInvariantMatcher
  module_function

  def candidate_ids(report, min_confidence: :low)
    report.findings.select do |finding|
      finding.classification != :blocked && finding.at_least?(min_confidence)
    end.to_set { |finding| finding.node.id }
  end

  def normalized_result(report)
    graph = report.graph
    graph_payload = graph.to_h.merge('call_sites' => graph.call_sites.map(&:to_h))
    {
      'summary' => canonical(report.summary),
      'findings' => sorted_payload(report.findings.map(&:to_h)),
      'graph' => canonical_graph(graph_payload),
      'diagnostics' => canonical(report.diagnostics),
      'reachability' => {
        'runtime_paths' => canonical(report.reachability.runtime_paths),
        'test_paths' => canonical(report.reachability.test_paths)
      }
    }
  end

  def canonical_graph(payload)
    sorted_keys = %w[nodes edges entry_points class_infos profiles blockers source_errors call_sites]
    payload.to_h do |key, value|
      normalized = if sorted_keys.include?(key)
                     sorted_payload(value)
                   elsif key == 'observation'
                     canonical_observation(value)
                   else
                     canonical(value)
                   end
      [key, normalized]
    end.sort.to_h
  end

  def canonical_observation(value)
    observation = canonical(value)
    analyzed_sites = observation.dig('rta', 'analyzed_sites')
    observation['rta']['analyzed_sites'] = sorted_payload(analyzed_sites) if analyzed_sites
    observation
  end

  def sorted_payload(items)
    Array(items).map { |item| canonical(item) }.sort_by { |item| JSON.generate(item) }
  end

  def canonical(value)
    case value
    when Hash
      value.to_h { |key, item| [key.to_s, canonical(item)] }.sort.to_h
    when Array
      value.map { |item| canonical(item) }
    else
      value
    end
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
