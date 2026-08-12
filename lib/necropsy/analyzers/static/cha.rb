# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class CHA < Analyzer
        def analyze(graph, _project)
          edge_evidences = []
          resolutions = graph.call_sites.map do |site|
            lookup = graph.cha_method_lookup(site)
            targets = lookup.targets
            site_edges = targets.map do |candidate|
              EdgeEvidence.new(
                caller_id: site.caller_id,
                callee_id: candidate.graph_id,
                evidence: evidence(
                  kind: :call_edge,
                  details: "CHA candidate at #{site.file}:#{site.line}",
                  metadata: site.to_h.merge('target_definition_id' => candidate.graph_id),
                  grade: :conservative,
                  relation: :call_edge,
                  source: call_site_evidence_source(site).merge('target_definition_id' => candidate.graph_id),
                  scope: call_site_evidence_scope(site).merge('target_definition_id' => candidate.graph_id)
                )
              )
            end
            edge_evidences.concat(site_edges)
            status = if lookup.complete?
                       :complete
                     else
                       (targets.empty? ? :unknown : :partial)
                     end
            resolution_record(
              site,
              targets,
              site_edges,
              status: status,
              rejected_targets: lookup.complete? ? lookup.rejected_targets : [],
              unknown_scope: graph.residual_scope_for(site)
            )
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: {},
            observation: {},
            resolutions: resolutions,
            evidences: result_evidences(edge_evidences)
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :cha,
            kind: :static,
            soundness: :conservative,
            description: 'Expands call targets through class hierarchy, descendants, and included/prepended modules.',
            version: Necropsy::VERSION,
            assumptions: %w[closed_scanned_hierarchy loaded_ancestry]
          )
        end
      end
    end
  end
end
