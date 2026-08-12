# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class NameResolution < Analyzer
        def analyze(graph, _project)
          edge_evidences = []
          resolutions = []
          uncertainties = {}
          blockers = []
          graph.call_sites.each do |site|
            lookup = graph.method_lookup(site)
            candidates = lookup.targets
            fallback = %w[dynamic_message unknown_receiver unknown_self_owner self_lookup_fallback].include?(
              lookup.reason
            )
            site_edges = edge_evidences_for(site, candidates, fallback, lookup)
            edge_evidences.concat(site_edges)
            resolutions << resolution_record(
              site,
              candidates,
              site_edges,
              status: lookup.status,
              rejected_targets: lookup.rejected_targets,
              unknown_scope: graph.residual_scope_for(site)
            )
            record_unresolved_uncertainty(graph, site, lookup, uncertainties)
            blocker = unresolved_blocker(graph, site, lookup)
            blockers << blocker if blocker
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: uncertainties,
            observation: {},
            blockers: blockers,
            resolutions: resolutions,
            evidences: result_evidences(edge_evidences)
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :name_resolution,
            kind: :static,
            soundness: :unsound,
            description: 'Resolves Ruby call sites by exact receiver and method name, falling back to same-name candidates.',
            version: Necropsy::VERSION,
            assumptions: %w[bounded_same_name_fallback scanned_receiver_hints]
          )
        end

        private

        def edge_evidences_for(site, candidates, fallback, lookup)
          candidates.map do |candidate|
            grade = if lookup.complete?
                      :exact
                    elsif fallback
                      :heuristic
                    else
                      :conservative
                    end
            EdgeEvidence.new(
              caller_id: site.caller_id,
              callee_id: candidate.graph_id,
              evidence: evidence(
                kind: :call_edge,
                details: "Name resolution#{' fallback' if fallback} at #{site.file}:#{site.line}",
                weight: fallback ? 0.35 : 1.0,
                metadata: site.to_h.merge(
                  'target_definition_id' => candidate.graph_id,
                  'lookup_status' => lookup.status.to_s,
                  'lookup_chain' => lookup.lookup_chain
                ),
                grade: grade,
                relation: :call_edge,
                source: call_site_evidence_source(site).merge('target_definition_id' => candidate.graph_id),
                scope: call_site_evidence_scope(site).merge('target_definition_id' => candidate.graph_id)
              )
            )
          end
        end

        def record_unresolved_uncertainty(graph, site, lookup, uncertainties)
          return if site.dynamic || lookup.targets.any? || lookup.complete?

          domain = site.test ? :test : :runtime
          return if graph.candidate_nodes(site.message, domain: domain).empty? && site.receiver_kind != :unknown

          uncertainties[site.caller_id] ||= []
          uncertainties[site.caller_id] <<
            "Unknown receiver for #{site.message} at #{site.file}:#{site.line}; dispatch may be ambiguous"
        end

        def unresolved_blocker(graph, site, lookup)
          return if lookup.targets.any? || lookup.complete?

          domain = site.test ? :test : :runtime
          candidate_count = graph.candidate_nodes(site.message, domain: domain).size
          limit_exceeded = graph.ambiguity_exceeded?(site.message, domain: domain)
          return unless limit_exceeded || site.receiver_kind == :unknown

          reason_code = limit_exceeded ? :ambiguity_limit_exceeded : :unknown_receiver
          scope_kind, scope_value = blocker_scope(graph, site)
          Blocker.new(
            kind: :unknown_dispatch,
            scope_kind: scope_kind,
            scope_value: scope_value,
            source: :name_resolution,
            reason: blocker_reason(site, candidate_count, reason_code),
            suggested_action: :review_receiver_flow,
            metadata: blocker_metadata(graph, site, candidate_count, reason_code)
          )
        end

        def blocker_scope(graph, site)
          return [:message, site.message] if site.receiver_kind == :unknown

          owners = receiver_hints(site)
          owners = [graph.nodes[site.caller_id]&.owner].compact if owners.empty?
          owners.empty? ? [:message, site.message] : [:owner, owners.sort]
        end

        def blocker_reason(site, candidate_count, reason_code)
          if reason_code == :ambiguity_limit_exceeded
            "Dispatch #{site.message} has #{candidate_count} candidates, exceeding the configured ambiguity limit"
          else
            "Receiver for #{site.message} is unknown and no candidate target could be materialized"
          end
        end

        def blocker_metadata(graph, site, candidate_count, reason_code)
          caller = graph.nodes[site.caller_id]
          owner_scope = receiver_hints(site)
          owner_scope = [caller&.owner].compact if owner_scope.empty? && site.receiver_kind != :unknown
          metadata = {
            'caller_id' => site.caller_id,
            'caller_kind' => caller&.kind&.to_s,
            'caller_domain' => site.test ? 'test' : 'runtime',
            'message' => site.message,
            'receiver_kind' => site.receiver_kind.to_s,
            'receiver_name' => site.receiver_name,
            'receiver_hints' => receiver_hints(site),
            'owner_scope' => owner_scope,
            'namespace_scope' => namespace_scope(owner_scope, caller&.owner),
            'file' => site.file,
            'line' => site.line,
            'candidate_count' => candidate_count,
            'ambiguity_limit' => finite_limit(graph.ambiguity_limit),
            'reason_code' => reason_code.to_s,
            'original_message' => site.metadata['original_message'] || site.metadata[:original_message]
          }
          return metadata unless site.metadata.key?('include_private') || site.metadata.key?(:include_private)

          metadata.merge('include_private' => site.metadata.fetch('include_private') { site.metadata[:include_private] })
        end

        def receiver_hints(site)
          candidates = site.metadata['receiver_candidates'] || site.metadata[:receiver_candidates]
          values = Array(candidates).compact
          values = [site.receiver_name].compact if values.empty?
          values.map(&:to_s).uniq
        end

        def namespace_scope(owner_scope, caller_owner)
          values = owner_scope.empty? ? [caller_owner].compact : owner_scope
          values.filter_map { |owner| owner.to_s.split('::')[0...-1].then { |parts| parts.join('::') unless parts.empty? } }.uniq
        end

        def finite_limit(limit)
          limit.finite? ? limit : 'unlimited'
        end
      end
    end
  end
end
