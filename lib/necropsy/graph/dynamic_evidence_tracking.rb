# frozen_string_literal: true

module Necropsy
  module DynamicEvidenceTracking
    SAMPLE_LIMIT = 5
    RESOLUTION_STATUSES = %w[exact unique ambiguous missing].freeze

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
      unmatched_nodes = result.alive_evidences.zip(alive_matches).filter_map do |_alive, resolution|
        dynamic_reference_label(resolution) if missing_dynamic_resolution?(resolution)
      end
      incomplete_nodes = alive_matches.filter_map do |resolution|
        dynamic_reference_label(resolution) unless precise_dynamic_resolution?(resolution)
      end
      incomplete_edges = edge_matches.filter_map { |match| incomplete_edge_sample(match) }

      update_dynamic_node_counts(diagnostic, alive_matches)
      update_dynamic_edge_counts(diagnostic, edge_matches)
      update_dynamic_resolution_counts(diagnostic, alive_matches, edge_matches)
      append_dynamic_samples(diagnostic, 'nodes', unmatched_nodes)
      append_dynamic_samples(diagnostic, 'edges', incomplete_edges)
      append_resolution_samples(diagnostic, alive_matches, edge_matches)
      warn_unmatched_dynamic_evidence(alive_matches, incomplete_nodes)
      warn_unmatched_dynamic_edges(edge_matches, incomplete_edges)
    end

    def empty_dynamic_evidence_diagnostic
      {
        'policy' => 'positive_only',
        'runtime_unobserved' => 'informational_only',
        'attempted' => { 'nodes' => 0, 'edges' => 0 },
        'matched' => { 'nodes' => 0, 'edges' => 0 },
        'partially_matched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched' => { 'nodes' => 0, 'edges' => 0 },
        'unmatched_samples' => { 'nodes' => [], 'edges' => [] },
        'resolution' => {
          'nodes' => empty_resolution_counts,
          'edge_endpoints' => empty_resolution_counts
        },
        'resolution_samples' => { 'nodes' => [], 'edge_endpoints' => [] }
      }
    end

    def empty_resolution_counts
      RESOLUTION_STATUSES.to_h { |status| [status, 0] }
    end

    def update_dynamic_node_counts(diagnostic, resolutions)
      diagnostic['attempted']['nodes'] += resolutions.length
      diagnostic['matched']['nodes'] += resolutions.count { |resolution| precise_dynamic_resolution?(resolution) }
      diagnostic['partially_matched']['nodes'] += resolutions.count { |resolution| ambiguous_dynamic_resolution?(resolution) }
      diagnostic['unmatched']['nodes'] += resolutions.count { |resolution| missing_dynamic_resolution?(resolution) }
    end

    def update_dynamic_edge_counts(diagnostic, matches)
      diagnostic['attempted']['edges'] += matches.length
      diagnostic['matched']['edges'] += matches.count { |match| fully_matched_edge?(match) }
      diagnostic['partially_matched']['edges'] += matches.count { |match| partially_matched_edge?(match) }
      diagnostic['unmatched']['edges'] += matches.count { |match| unmatched_edge?(match) }
    end

    def update_dynamic_resolution_counts(diagnostic, nodes, edges)
      nodes.each { |resolution| increment_resolution_count(diagnostic, 'nodes', resolution) }
      edges.each do |match|
        increment_resolution_count(diagnostic, 'edge_endpoints', match.fetch(:caller))
        increment_resolution_count(diagnostic, 'edge_endpoints', match.fetch(:callee))
      end
    end

    def increment_resolution_count(diagnostic, kind, resolution)
      diagnostic['resolution'][kind][resolution.fetch(:status).to_s] += 1
    end

    def fully_matched_edge?(match)
      match.fetch(:materialized)
    end

    def partially_matched_edge?(match)
      !fully_matched_edge?(match) && !unmatched_edge?(match)
    end

    def unmatched_edge?(match)
      missing_dynamic_resolution?(match.fetch(:caller)) && missing_dynamic_resolution?(match.fetch(:callee))
    end

    def ambiguous_dynamic_resolution?(resolution)
      resolution.fetch(:status) == :ambiguous
    end

    def missing_dynamic_resolution?(resolution)
      resolution.fetch(:status) == :missing
    end

    def incomplete_edge_sample(match)
      return if fully_matched_edge?(match)

      caller = match.fetch(:caller)
      callee = match.fetch(:callee)
      incomplete = []
      missing = dynamic_endpoints_with_status(caller, callee, :missing)
      ambiguous = dynamic_endpoints_with_status(caller, callee, :ambiguous)
      incomplete << "unmatched #{missing.join(', ')}" unless missing.empty?
      incomplete << "ambiguous #{ambiguous.join(', ')}" unless ambiguous.empty?
      "#{dynamic_reference_label(caller)} -> #{dynamic_reference_label(callee)} (#{incomplete.join(', ')})"
    end

    def dynamic_endpoints_with_status(caller, callee, status)
      { 'caller' => caller, 'callee' => callee }.filter_map do |endpoint, resolution|
        "#{endpoint}: #{dynamic_reference_label(resolution)}" if resolution.fetch(:status) == status
      end
    end

    def dynamic_reference_label(resolution)
      reference = resolution.fetch(:reference)
      return reference.fetch('identifier') if reference.key?('identifier')

      identifier = reference['definition_id'] || reference['symbol_id'] || '<invalid>'
      location = [reference['file'], reference['line']].compact.join(':')
      location.empty? ? identifier : "#{identifier} @ #{location}"
    end

    def append_dynamic_samples(diagnostic, kind, samples)
      combined = diagnostic['unmatched_samples'][kind] + samples
      diagnostic['unmatched_samples'][kind] = combined.uniq.sort.first(SAMPLE_LIMIT)
    end

    def append_resolution_samples(diagnostic, nodes, edges)
      node_samples = nodes.map { |resolution| resolution_sample(resolution) }
      endpoint_samples = edges.flat_map do |match|
        %i[caller callee].map do |endpoint|
          resolution_sample(match.fetch(endpoint)).merge('endpoint' => endpoint.to_s)
        end
      end
      append_bounded_resolution_samples(diagnostic, 'nodes', node_samples)
      append_bounded_resolution_samples(diagnostic, 'edge_endpoints', endpoint_samples)
    end

    def resolution_sample(resolution)
      {
        'reference' => resolution.fetch(:reference),
        'status' => resolution.fetch(:status).to_s,
        'definition_ids' => resolution.fetch(:definitions).map(&:graph_id).sort
      }
    end

    def append_bounded_resolution_samples(diagnostic, kind, samples)
      combined = diagnostic['resolution_samples'][kind] + samples
      diagnostic['resolution_samples'][kind] = combined.uniq.sort_by do |sample|
        canonical_dynamic_sample(sample)
      end.first(SAMPLE_LIMIT)
    end

    def canonical_dynamic_sample(value)
      case value
      when Hash
        value.keys.sort.map { |key| [key, canonical_dynamic_sample(value.fetch(key))] }
      when Array
        value.map { |item| canonical_dynamic_sample(item) }
      else
        value.to_s
      end
    end

    def warn_unmatched_dynamic_evidence(matches, samples)
      return if samples.empty?

      precise = matches.count { |resolution| precise_dynamic_resolution?(resolution) }
      ambiguous = matches.count { |resolution| ambiguous_dynamic_resolution?(resolution) }
      missing = matches.count { |resolution| missing_dynamic_resolution?(resolution) }
      warn "Necropsy matched #{precise} of #{matches.length} dynamic node IDs precisely; ambiguous #{ambiguous}; " \
           "missing #{missing}; unresolved: #{samples.first(SAMPLE_LIMIT).join(', ')}"
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
