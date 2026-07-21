# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Static
      class CHA < Analyzer
        def analyze(graph, _project)
          edge_evidences = graph.call_sites.flat_map do |site|
            candidates(graph, site).map do |candidate|
              EdgeEvidence.new(
                caller_id: site.caller_id,
                callee_id: candidate.id,
                evidence: evidence(
                  kind: :call_edge,
                  details: "CHA candidate at #{site.file}:#{site.line}",
                  metadata: site.to_h
                )
              )
            end
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: [],
            uncertainties: {},
            observation: {}
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :cha,
            kind: :static,
            soundness: :conservative,
            description: 'Expands call targets through class hierarchy, descendants, and included/prepended modules.'
          )
        end

        def candidates(graph, site)
          case site.receiver_kind
          when :constant
            constant_targets(graph, site)
          when :instance
            instance_targets(graph, site)
          when :self, :implicit
            self_targets(graph, site)
          else
            graph.resolve_call_site(site)
          end.uniq(&:id)
        end

        private

        def constant_targets(graph, site)
          receiver_candidates(site).flat_map do |owner|
            targets = owners_for_lookup(graph, owner, include_descendants: false).filter_map do |candidate_owner|
              graph.nodes["#{candidate_owner}.#{site.message}"]
            end
            extended = Array(graph.class_info(owner)&.extends).filter_map do |mod|
              graph.nodes["#{mod}##{site.message}"]
            end
            targets + extended
          end
        end

        def instance_targets(graph, site)
          receiver_candidates(site).flat_map do |owner|
            owners_for_lookup(graph, owner, include_descendants: true).filter_map do |candidate_owner|
              graph.nodes["#{candidate_owner}##{site.message}"]
            end
          end
        end

        def self_targets(graph, site)
          caller = graph.nodes[site.caller_id]
          return [] unless caller&.owner

          separator = caller.kind == :singleton_method ? '.' : '#'
          owners_for_lookup(graph, caller.owner, include_descendants: false).filter_map do |owner|
            graph.nodes["#{owner}#{separator}#{site.message}"] || graph.nodes["#{owner}##{site.message}"]
          end
        end

        def owners_for_lookup(graph, owner, include_descendants:)
          owners = include_descendants ? graph.descendants_of(owner) : [owner]
          owners.flat_map do |candidate|
            info = graph.class_info(candidate)
            modules = info ? info.prepends + info.includes + info.extends : []
            [candidate, *modules, *ancestors(graph, candidate)]
          end.uniq
        end

        def ancestors(graph, owner)
          chain = []
          current = graph.class_info(owner)&.superclass
          while current && !chain.include?(current)
            chain << current
            current = graph.class_info(current)&.superclass
          end
          chain
        end

        def receiver_candidates(site)
          candidates = site.metadata['receiver_candidates'] || site.metadata[:receiver_candidates]
          Array(candidates).compact.empty? ? [site.receiver_name].compact : Array(candidates).compact
        end
      end
    end
  end
end
