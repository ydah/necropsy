# frozen_string_literal: true

require 'digest'

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

        attr_reader :pruning, :emit_redundant_edges

        def initialize(pruning: :rank_only, emit_redundant_edges: true)
          mode = pruning.to_s
          unless Configuration::RTA_PRUNING_MODES.include?(mode)
            raise Error, "RTA pruning must be one of: #{Configuration::RTA_PRUNING_MODES.join(', ')}"
          end

          @pruning = mode.to_sym
          @emit_redundant_edges = emit_redundant_edges == true
        end

        def with_pruning(mode, emit_redundant_edges: @emit_redundant_edges)
          self.class.new(pruning: mode, emit_redundant_edges: emit_redundant_edges)
        end

        def without_redundant_edges
          self.class.new(pruning: pruning, emit_redundant_edges: false)
        end

        def analyze(graph, _project)
          sites = expanded_call_sites(graph)
          instantiated_metadata = instantiated_classes_metadata(graph)
          analyses = sites.map do |site|
            targets = rta_candidates(graph, site)
            site_edges = targets.filter_map do |candidate|
              # In rank-only mode CHA/name resolution already materialize the
              # same conservative edge. Keep the RTA resolution record, but
              # avoid allocating a duplicate evidence object for an edge that
              # cannot change reachability. Legacy pruning still emits every
              # candidate because reconciliation uses those edge identities.
              next if pruning == :rank_only && !emit_redundant_edges &&
                      graph.edge_present?(site.caller_id, candidate.graph_id)

              EdgeEvidence.new(
                caller_id: site.caller_id,
                callee_id: candidate.graph_id,
                evidence: evidence(
                  kind: :call_edge,
                  details: "RTA candidate at #{site.file}:#{site.line}",
                  metadata: site.to_h.merge(instantiated_metadata).merge('target_definition_id' => candidate.graph_id),
                  grade: :heuristic,
                  relation: :call_edge,
                  source: call_site_evidence_source(site).merge('target_definition_id' => candidate.graph_id),
                  scope: call_site_evidence_scope(site).merge('target_definition_id' => candidate.graph_id)
                )
              )
            end
            [site, targets, site_edges]
          end
          edge_evidences = analyses.flat_map(&:last)
          analyses_by_call_site_id = analyses.to_h { |site, targets, edges| [site.call_site_id, [targets, edges]] }
          resolutions = graph.call_sites.map do |site|
            targets, edges = analyses_by_call_site_id.fetch(site.call_site_id)
            resolution_record(site, targets, edges)
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: {},
            observation: { 'rta' => { 'pruning' => pruning.to_s, 'analyzed_sites' => sites.map(&:to_h) } },
            resolutions: resolutions,
            evidences: result_evidences(edge_evidences)
          )
        end

        def profile
          description = if pruning == :legacy
                          'RTA pruning mode legacy removes static candidates without scanned construction evidence.'
                        else
                          'RTA pruning mode rank_only records constructed-class hints without removing static edges.'
                        end
          AnalyzerProfile.new(
            name: :rta,
            kind: :static,
            soundness: :partial,
            description: description,
            version: Necropsy::VERSION,
            assumptions: ['scanned_allocations', "pruning=#{pruning}"]
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
              call_site_id: CallSiteIdentity.derived_id(
                parent_call_site_id: site.call_site_id,
                derivation: :rta_implicit,
                caller_definition_id: site.caller_id,
                message: message
              ),
              caller_id: site.caller_id,
              message: message,
              receiver_kind: site.receiver_kind,
              receiver_name: site.receiver_name,
              file: site.file,
              line: site.line,
              test: site.test,
              dynamic: site.dynamic,
              metadata: site.metadata.merge(
                'implicit_from' => site.message,
                'derived_from_call_site_id' => site.call_site_id,
                'derived_via' => 'rta_implicit'
              )
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

        # A full allocation list in every RTA evidence record makes evidence
        # identity canonicalization quadratic for a repository with many
        # scanned constructors. Keep the complete list for small fixtures
        # (preserving the existing diagnostic shape), and use a deterministic
        # bounded sample plus digest for larger projects.
        def instantiated_classes_metadata(graph)
          classes = graph.instantiated_classes.to_a.sort
          return { 'instantiated_classes' => classes } if classes.length <= 64

          {
            'instantiated_classes' => classes.first(16),
            'instantiated_classes_count' => classes.length,
            'instantiated_classes_truncated' => true,
            'instantiated_classes_sha256' => Digest::SHA256.hexdigest(classes.join("\0"))
          }
        end
      end
    end
  end
end
