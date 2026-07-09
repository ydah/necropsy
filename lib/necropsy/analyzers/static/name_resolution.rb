# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class NameResolution < Analyzer
        def analyze(graph, _project)
          edge_evidences = graph.call_sites.flat_map do |site|
            graph.resolve_call_site(site).map do |candidate|
              EdgeEvidence.new(
                caller_id: site.caller_id,
                callee_id: candidate.id,
                evidence: evidence(
                  kind: :call_edge,
                  details: "Name resolution at #{site.file}:#{site.line}",
                  metadata: site.to_h
                )
              )
            end
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: unresolved_uncertainties(graph),
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

        def unresolved_uncertainties(graph)
          graph.call_sites.each_with_object({}) do |site, memo|
            next if site.dynamic
            next unless graph.resolve_call_site(site).empty? && site.receiver_kind == :unknown

            memo[site.caller_id] ||= []
            memo[site.caller_id] << "Unknown receiver for #{site.message} at #{site.file}:#{site.line}"
          end
        end
      end
    end
  end
end
