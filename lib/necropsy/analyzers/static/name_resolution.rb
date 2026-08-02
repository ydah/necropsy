# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class NameResolution < Analyzer
        def analyze(graph, _project)
          edge_evidences = []
          uncertainties = {}
          graph.call_sites.each do |site|
            candidates = graph.resolve_call_site(site)
            fallback = graph.fallback_resolution?(site, resolved: candidates)
            edge_evidences.concat(edge_evidences_for(site, candidates, fallback))
            record_unresolved_uncertainty(graph, site, candidates, uncertainties)
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: uncertainties,
            observation: {}
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :name_resolution,
            kind: :static,
            soundness: :unsound,
            description: 'Resolves Ruby call sites by exact receiver and method name, falling back to same-name candidates.'
          )
        end

        private

        def edge_evidences_for(site, candidates, fallback)
          candidates.map do |candidate|
            EdgeEvidence.new(
              caller_id: site.caller_id,
              callee_id: candidate.id,
              evidence: evidence(
                kind: :call_edge,
                details: "Name resolution#{' fallback' if fallback} at #{site.file}:#{site.line}",
                weight: fallback ? 0.35 : 1.0,
                metadata: site.to_h
              )
            )
          end
        end

        def record_unresolved_uncertainty(graph, site, candidates, uncertainties)
          return if site.dynamic || candidates.any?
          return if graph.candidate_nodes(site.message).empty? && site.receiver_kind != :unknown

          uncertainties[site.caller_id] ||= []
          uncertainties[site.caller_id] <<
            "Unknown receiver for #{site.message} at #{site.file}:#{site.line}; dispatch may be ambiguous"
        end
      end
    end
  end
end
