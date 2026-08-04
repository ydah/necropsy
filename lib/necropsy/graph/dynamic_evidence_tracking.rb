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
      unmatched_edges = result.edge_evidences.zip(edge_matches).filter_map do |edge, matched|
        "#{edge.caller_id} -> #{edge.callee_id}" unless matched
      end

      update_dynamic_counts(diagnostic, 'nodes', alive_matches)
      update_dynamic_counts(diagnostic, 'edges', edge_matches)
      append_dynamic_samples(diagnostic, 'nodes', unmatched_nodes)
      append_dynamic_samples(diagnostic, 'edges', unmatched_edges)
      warn_unmatched_dynamic_evidence('node IDs', alive_matches, unmatched_nodes)
      warn_unmatched_dynamic_evidence('edges', edge_matches, unmatched_edges)
    end

    def empty_dynamic_evidence_diagnostic
      {
        'policy' => 'positive_only',
        'runtime_unobserved' => 'informational_only',
        'attempted' => { 'nodes' => 0, 'edges' => 0 },
        'matched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched_samples' => { 'nodes' => [], 'edges' => [] }
      }
    end

    def update_dynamic_counts(diagnostic, kind, matches)
      diagnostic['attempted'][kind] += matches.length
      diagnostic['matched'][kind] += matches.count(true)
      diagnostic['unmatched'][kind] += matches.count(false)
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
  end
end
