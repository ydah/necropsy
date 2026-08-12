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
        CORE_ENUMERABLE_RECEIVERS = %w[Array Enumerator Hash Range Set].freeze
        CORE_COMPARISON_RECEIVERS = %w[Array].freeze
        KERNEL_OUTPUT_MESSAGES = %w[print puts warn].freeze
        BLOCK_DEPENDENT_ENUMERABLE_MESSAGES = %w[
          all? any? chunk collect cycle detect drop_while each_cons each_entry each_slice
          each_with_index each_with_object filter find find_all flat_map group_by
          map none? one? partition reject reverse_each select sort_by take_while
        ].freeze
        BLOCK_COMPARISON_MESSAGES = %w[max min sort].freeze

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
          original_call_site_ids = graph.call_sites.to_set(&:call_site_id)
          derived_sites = sites.reject { |site| original_call_site_ids.include?(site.call_site_id) }
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
          resolutions = sites.map do |site|
            targets, edges = analyses_by_call_site_id.fetch(site.call_site_id)
            resolution_record(site, targets, edges, unknown_scope: graph.residual_scope_for(site))
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: {},
            observation: { 'rta' => { 'pruning' => pruning.to_s, 'analyzed_sites' => sites.map(&:to_h) } },
            resolutions: resolutions,
            evidences: result_evidences(edge_evidences),
            derived_call_sites: derived_sites
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

        def capabilities
          [:complete_resolution].freeze
        end

        def expanded_call_sites(graph)
          graph.call_sites.flat_map do |site|
            [site, *implicit_sites(site, graph: graph)]
          end
        end

        def implicit_sites(site, graph: nil)
          summaries = []
          summaries << ['each', :same_receiver] if core_enumerable_receiver?(site) && enumerable_protocol?(site)
          summaries.concat(comparison_summaries(site)) if core_comparison_receiver?(site)
          summaries.concat(output_summaries(site)) if kernel_output_call?(site, graph)
          summaries.map.with_index do |(message, receiver), index|
            derived_protocol_site(site, message, receiver, index: index)
          end
        end

        def implicit_messages(site, graph: nil)
          implicit_sites(site, graph: graph).map(&:message)
        end

        private

        def derived_protocol_site(site, message, receiver, index: 0)
          receiver_kind, receiver_name, receiver_metadata = protocol_receiver(site, receiver)
          receiver_label = protocol_receiver_label(receiver)
          CallSite.new(
            call_site_id: CallSiteIdentity.derived_id(
              parent_call_site_id: site.call_site_id,
              derivation: :rta_implicit,
              caller_definition_id: site.caller_id,
              message: message,
              discriminator: index.positive? ? "#{receiver_label}:#{index}" : nil
            ),
            caller_id: site.caller_id,
            message: message,
            receiver_kind: receiver_kind,
            receiver_name: receiver_name,
            file: site.file,
            line: site.line,
            test: site.test,
            dynamic: false,
            metadata: site.metadata.except('receiver_candidates', 'receiver_value_fact').merge(
              receiver_metadata,
              'implicit_from' => site.message,
              'protocol_receiver' => receiver_label,
              'derived_from_call_site_id' => site.call_site_id,
              'derived_via' => 'rta_implicit'
            )
          )
        end

        def protocol_receiver(site, receiver)
          if receiver == :same_receiver
            metadata = site.metadata.slice('receiver_candidates', 'receiver_value_fact')
            return [site.receiver_kind, site.receiver_name, metadata]
          end

          argument_index = receiver[1] if receiver.is_a?(Array) && receiver.first == :argument
          fact = Array(site.metadata['argument_value_facts'])[argument_index] if argument_index
          fact = site.metadata.dig('receiver_value_fact', 'summary', 'element_fact') if receiver == :element_receiver
          return receiver_from_fact(fact) if fact

          [:unknown, nil, { 'receiver_candidates' => [] }]
        end

        def receiver_from_fact(fact)
          return [:unknown, nil, { 'receiver_candidates' => [] }] unless fact.is_a?(Hash)
          return [:unknown, nil, { 'receiver_candidates' => [] }] unless fact['kind'].to_s == 'instance_types'
          return [:unknown, nil, { 'receiver_candidates' => [] }] unless fact['exact'] == true

          values = Array(fact['values']).map(&:to_s).reject(&:empty?).uniq.sort
          return [:unknown, nil, { 'receiver_candidates' => [] }] if values.empty?

          [:instance, values.first, { 'receiver_candidates' => values, 'receiver_value_fact' => fact }]
        end

        def core_enumerable_receiver?(site)
          receiver_owners(site).intersect?(CORE_ENUMERABLE_RECEIVERS)
        end

        def core_comparison_receiver?(site)
          receiver_owners(site).intersect?(CORE_COMPARISON_RECEIVERS)
        end

        def enumerable_protocol?(site)
          return false unless ENUMERABLE_MESSAGES.include?(site.message) && site.message != 'each'
          return true unless BLOCK_DEPENDENT_ENUMERABLE_MESSAGES.include?(site.message)

          site.metadata['block_kind'] != 'none'
        end

        def comparison_protocol?(site)
          return false unless COMPARISON_MESSAGES.include?(site.message)
          return true unless BLOCK_COMPARISON_MESSAGES.include?(site.message)

          !site.metadata.key?('block_kind') || %w[none nil dynamic].include?(site.metadata['block_kind'])
        end

        def comparison_summaries(site)
          if site.message == 'sort_by'
            return [] if %w[none nil].include?(site.metadata['block_kind'])

            return [['<=>', :block_result_receiver]]
          end

          comparison_protocol?(site) ? [['<=>', :element_receiver]] : []
        end

        def output_summaries(site)
          facts = Array(site.metadata['argument_value_facts'])
          count = [facts.length, site.metadata.dig('arguments', 'positional_count').to_i].max
          count = 1 if count.zero? && !site.metadata.key?('arguments')
          count.times.map { |index| ['to_s', [:argument, index]] }
        end

        def protocol_receiver_label(receiver)
          return 'first_argument' if receiver == [:argument, 0]
          return "argument_#{receiver[1]}" if receiver.is_a?(Array) && receiver.first == :argument

          receiver.to_s
        end

        def receiver_owners(site)
          values = Array(site.metadata['receiver_candidates'])
          values = [container_receiver_owner(site.metadata['receiver_value_fact'])] if values.empty?
          values = [site.receiver_name] if values.empty?
          values.compact.map(&:to_s)
        end

        def container_receiver_owner(fact)
          return unless fact.is_a?(Hash) && fact['kind'].to_s == 'container' && fact['exact'] == true

          { 'array' => 'Array', 'hash' => 'Hash' }[fact.dig('summary', 'type').to_s]
        end

        def kernel_output_call?(site, graph)
          return false unless KERNEL_OUTPUT_MESSAGES.include?(site.message)
          return false unless %i[implicit self].include?(site.receiver_kind)
          return true unless graph

          graph.method_lookup(site).targets.empty?
        end

        def rta_candidates(graph, site)
          candidates = graph.cha_method_lookup(site).targets
          candidates = fallback_candidates(graph, site) if candidates.empty?
          graph.retain_rta_candidates(candidates, site)
        end

        def fallback_candidates(graph, site)
          domain = site.test ? :test : :runtime
          return graph.candidate_nodes(site.message, domain: domain) if site.receiver_kind == :unknown
          return [] unless graph.ambiguous_resolution?

          graph.ambiguous_fallback_candidates(site.message, domain: domain)
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
