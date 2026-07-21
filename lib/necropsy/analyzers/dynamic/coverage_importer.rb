# frozen_string_literal: true

require 'json'
require 'yaml'

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
          alive = Array(payload['executed'] || payload['nodes']).map do |node_id|
            AliveEvidence.new(
              node_id: node_id,
              evidence: evidence(kind: :alive, details: "Coverage marked #{node_id} as executed",
                                 metadata: payload['observation'] || {})
            )
          end

          edge_evidences = Array(payload['edges']).map do |edge|
            caller_id = edge['caller_id'] || edge[:caller_id]
            callee_id = edge['callee_id'] || edge[:callee_id]
            EdgeEvidence.new(
              caller_id: caller_id,
              callee_id: callee_id,
              evidence: evidence(kind: :call_edge, details: "Coverage observed #{caller_id} -> #{callee_id}")
            )
          end

          AnalyzerResult.new(
            edge_evidences: edge_evidences,
            alive_evidences: alive,
            uncertainties: {},
            observation: { 'coverage' => payload['observation'] || {} }
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :coverage,
            kind: :dynamic,
            soundness: :observational,
            description: 'Imports method execution and observed edges from Ruby Coverage output.'
          )
        end

        private

        attr_reader :config

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
