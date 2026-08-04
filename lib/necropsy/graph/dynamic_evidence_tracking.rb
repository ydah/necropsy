# frozen_string_literal: true

module Necropsy
  module DynamicEvidenceTracking
    SAMPLE_LIMIT = 5

    def dynamic_observation?
      observation.key?('dynamic_evidence')
    end

    def dynamic_evidence_diagnostic
      observation['dynamic_evidence']
    end

    private

    def dynamic_result?(result)
      return true unless result.alive_evidences.empty?

      dynamic_profiles = profiles.select { |profile| profile.kind == :dynamic }.map { |profile| profile.name.to_s }
      evidence_analyzers = result.edge_evidences.map { |edge| edge.evidence.analyzer.to_s }
      return true if dynamic_profiles.intersect?(evidence_analyzers)

      observation_keys = result.observation.keys.map(&:to_s)
      observation_keys.intersect?(dynamic_profiles) || observation_keys.intersect?(%w[coverage coverband trace_point])
    end

    def record_dynamic_evidence(result, alive_matches, edge_matches)
      diagnostic = observation['dynamic_evidence'] ||= empty_dynamic_evidence_diagnostic
      unmatched_nodes = result.alive_evidences.zip(alive_matches).filter_map do |alive, matched|
        alive.node_id unless matched
      end
      unmatched_edges = edge_matches.filter_map { |match| unmatched_edge_sample(match) }

      update_dynamic_counts(diagnostic, 'nodes', alive_matches)
      update_dynamic_edge_counts(diagnostic, edge_matches)
      append_dynamic_samples(diagnostic, 'nodes', unmatched_nodes)
      append_dynamic_samples(diagnostic, 'edges', unmatched_edges)
      warn_unmatched_dynamic_evidence('node IDs', alive_matches, unmatched_nodes)
      warn_unmatched_dynamic_edges(edge_matches, unmatched_edges)
    end

    def empty_dynamic_evidence_diagnostic
      {
        'policy' => 'positive_only',
        'runtime_unobserved' => 'informational_only',
        'attempted' => { 'nodes' => 0, 'edges' => 0 },
        'matched' => { 'nodes' => 0, 'edges' => 0 },
        'partially_matched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched_samples' => { 'nodes' => [], 'edges' => [] }
      }
    end

    def update_dynamic_counts(diagnostic, kind, matches)
      diagnostic['attempted'][kind] += matches.length
      diagnostic['matched'][kind] += matches.count(true)
      diagnostic['unmatched'][kind] += matches.count(false)
    end

    def update_dynamic_edge_counts(diagnostic, matches)
      diagnostic['attempted']['edges'] += matches.length
      diagnostic['matched']['edges'] += matches.count { |match| fully_matched_edge?(match) }
      diagnostic['partially_matched']['edges'] += matches.count { |match| partially_matched_edge?(match) }
      diagnostic['unmatched']['edges'] += matches.count { |match| unmatched_edge?(match) }
    end

    def fully_matched_edge?(match)
      match[:caller] && match[:callee]
    end

    def partially_matched_edge?(match)
      match.values_at(:caller, :callee).count(true) == 1
    end

    def unmatched_edge?(match)
      !match[:caller] && !match[:callee]
    end

    def unmatched_edge_sample(match)
      return if fully_matched_edge?(match)

      missing = []
      missing << "caller: #{match[:caller_id]}" unless match[:caller]
      missing << "callee: #{match[:callee_id]}" unless match[:callee]
      "#{match[:caller_id]} -> #{match[:callee_id]} (unmatched #{missing.join(', ')})"
    end

    def append_dynamic_samples(diagnostic, kind, samples)
      combined = diagnostic['unmatched_samples'][kind] + samples
      diagnostic['unmatched_samples'][kind] = combined.uniq.first(SAMPLE_LIMIT)
    end

    def warn_unmatched_dynamic_evidence(kind, matches, samples)
      return if samples.empty?

      warn "Necropsy matched #{matches.count(true)} of #{matches.length} dynamic #{kind}; " \
           "ignored #{samples.length} unmatched: #{samples.first(SAMPLE_LIMIT).join(', ')}"
    end

    def warn_unmatched_dynamic_edges(matches, samples)
      return if samples.empty?

      full = matches.count { |match| fully_matched_edge?(match) }
      partial = matches.count { |match| partially_matched_edge?(match) }
      unmatched = matches.count { |match| unmatched_edge?(match) }
      warn "Necropsy fully matched #{full} of #{matches.length} dynamic edges; partially matched #{partial}; " \
           "unmatched #{unmatched}; unmatched endpoints: #{samples.first(SAMPLE_LIMIT).join(', ')}"
    end
  end
end
