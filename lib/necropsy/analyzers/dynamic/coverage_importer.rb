# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'runtime_reference'

module Necropsy
  module Analyzers
    module Dynamic
      class CoverageImporter < Analyzer
        def initialize(config)
          @config = config || {}
        end

        def analyze(_graph, project)
          source = config['source']
          return AnalyzerResult.empty unless source

          payload = load_payload(File.expand_path(source, project.root))
          observation = ObservationPolicy.metadata(payload, expected_revision: config['expected_source_revision'])
          malformed = []
          alive = node_references(payload).map do |raw_reference|
            node_id = normalized_or_raw(raw_reference, malformed, :node)
            AliveEvidence.new(
              node_id: node_id,
              evidence: evidence(
                kind: :alive,
                details: "Coverage marked #{reference_label(node_id)} as executed",
                metadata: observation.merge('node_reference' => node_id),
                grade: :observed,
                relation: :execution,
                source: { 'type' => profile.name.to_s, 'node_reference' => node_id },
                scope: ObservationPolicy.evidence_scope(observation).merge('node_reference' => node_id)
              )
            )
          end

          edge_evidences = edge_references(payload).filter_map do |edge|
            unless edge.is_a?(Hash)
              malformed << malformed_reference(:edge, edge)
              next
            end

            caller = edge['caller_id'] || edge[:caller_id]
            callee = edge['callee_id'] || edge[:callee_id]
            caller_id = normalized_or_raw(caller, malformed, :edge_caller)
            callee_id = normalized_or_raw(callee, malformed, :edge_callee)
            EdgeEvidence.new(
              caller_id: caller_id,
              callee_id: callee_id,
              evidence: evidence(
                kind: :call_edge,
                details: "Coverage observed #{reference_label(caller_id)} -> #{reference_label(callee_id)}",
                metadata: { 'caller_reference' => caller_id, 'callee_reference' => callee_id },
                grade: :observed,
                relation: :observed_call,
                source: {
                  'type' => profile.name.to_s,
                  'caller_reference' => caller_id,
                  'callee_reference' => callee_id
                },
                scope: ObservationPolicy.evidence_scope(observation).merge(
                  'caller_reference' => caller_id,
                  'callee_reference' => callee_id
                )
              )
            )
          end
          observation = observation.merge('malformed_references' => malformed) unless malformed.empty?

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: alive,
            uncertainties: {},
            observation: { 'coverage' => observation },
            resolutions: [],
            evidences: result_evidences(edge_evidences, alive)
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :coverage,
            kind: :dynamic,
            soundness: :observational,
            description: 'Imports method execution and observed edges from Ruby Coverage output.',
            version: Necropsy::VERSION,
            assumptions: ['positive_observations_only']
          )
        end

        private

        attr_reader :config

        def node_references(payload)
          structured = payload['node_references'] if payload.key?('node_references')
          RuntimeReference.preferred(structured: structured, legacy: payload['executed'] || payload['nodes'])
        end

        def edge_references(payload)
          structured = payload['edge_references'] if payload.key?('edge_references')
          return Array(payload['edges']) if structured.nil?

          structured_edges = Array(structured)
          structured_pairs = structured_edges.filter_map { |edge| edge_symbol_pair(edge) }.to_set
          structured_edges + Array(payload['edges']).reject do |edge|
            structured_pairs.include?(edge_symbol_pair(edge))
          end
        end

        def edge_symbol_pair(edge)
          return unless edge.is_a?(Hash)

          caller = RuntimeReference.normalize(edge['caller_id'] || edge[:caller_id])
          callee = RuntimeReference.normalize(edge['callee_id'] || edge[:callee_id])
          return unless caller && callee

          [reference_symbol(caller), reference_symbol(callee)]
        end

        def reference_symbol(reference)
          reference.is_a?(Hash) ? reference['symbol_id'] : reference
        end

        def normalized_or_raw(reference, malformed, kind)
          normalized = RuntimeReference.normalize(reference)
          return normalized if normalized

          malformed << malformed_reference(kind, reference)
          reference
        end

        def malformed_reference(kind, reference)
          { 'kind' => kind.to_s, 'reference' => reference }
        end

        def reference_label(reference)
          return reference.to_s unless reference.is_a?(Hash)

          symbol = reference['symbol_id'] || reference[:symbol_id] || '<missing symbol>'
          file = reference['file'] || reference[:file]
          line = reference['line'] || reference[:line]
          location = [file, line].compact.join(':')
          location.empty? ? symbol.to_s : "#{symbol} at #{location}"
        end

        def load_payload(path)
          raise Error, "Coverage source does not exist: #{path}" unless File.file?(path)

          case File.extname(path)
          when '.json'
            JSON.parse(File.read(path))
          else
            YAML.safe_load_file(path, aliases: false) || {}
          end
        rescue JSON::ParserError, Psych::Exception => e
          raise Error, "Could not parse coverage source #{path}: #{e.message}"
        end
      end
    end
  end
end
