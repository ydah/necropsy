# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class RTA < Analyzer
        ENUMERABLE_MESSAGES = %w[
          all? any? chunk collect count cycle detect drop drop_while each_cons each_entry
          each_slice each_with_index each_with_object entries filter find find_all flat_map
          grep group_by include? inject map max min none? one? partition reduce reject
          reverse_each select sort sort_by take take_while to_a to_h
        ].freeze
        COMPARISON_MESSAGES = %w[< <= > >= between? clamp sort sort_by max min].freeze

        def analyze(graph, _project)
          sites = expanded_call_sites(graph)
          edge_evidences = sites.flat_map do |site|
            rta_candidates(graph, site).map do |candidate|
              EdgeEvidence.new(
                caller_id: site.caller_id,
                callee_id: candidate.id,
                evidence: evidence(
                  kind: :call_edge,
                  details: "RTA candidate at #{site.file}:#{site.line}",
                  metadata: site.to_h.merge('instantiated_classes' => graph.instantiated_classes.to_a.sort)
                )
              )
            end
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: {},
            observation: { 'rta' => { 'analyzed_sites' => sites.map(&:to_h) } }
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :rta,
            kind: :static,
            soundness: :partial,
            description: 'Marks constructed-class dispatch candidates as ranking and diagnostic evidence.'
          )
        end

        def expanded_call_sites(graph)
          graph.call_sites.flat_map do |site|
            [site, *implicit_sites(site)]
          end
        end

        def implicit_sites(site)
          implicit_messages(site.message).map do |message|
            CallSite.new(
              caller_id: site.caller_id,
              message: message,
              receiver_kind: site.receiver_kind,
              receiver_name: site.receiver_name,
              file: site.file,
              line: site.line,
              test: site.test,
              dynamic: site.dynamic,
              metadata: site.metadata.merge('implicit_from' => site.message)
            )
          end
        end

        def implicit_messages(message)
          messages = []
          messages << 'each' if ENUMERABLE_MESSAGES.include?(message) && message != 'each'
          messages << '<=>' if COMPARISON_MESSAGES.include?(message)
          messages << 'to_s' if %w[puts print warn].include?(message)
          messages
        end

        private

        def rta_candidates(graph, site)
          candidates = Analyzers::Static::CHA.new.candidates(graph, site)
          candidates = fallback_candidates(graph, site) if candidates.empty?
          graph.retain_rta_candidates(candidates, site)
        end

        def fallback_candidates(graph, site)
          return graph.candidate_nodes(site.message) if site.receiver_kind == :unknown
          return [] unless graph.ambiguous_resolution?

          graph.ambiguous_fallback_candidates(site.message)
        end
      end
    end
  end
end
