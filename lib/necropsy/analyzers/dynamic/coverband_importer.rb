# frozen_string_literal: true

require 'json'
require 'yaml'

require_relative 'redis_payload_loader'

module Necropsy
  module Analyzers
    module Dynamic
      class CoverbandImporter < Analyzer
        def initialize(config)
          @config = config || {}
        end

        def analyze(graph, project)
          source = config['source']
          return AnalyzerResult.empty unless source

          payload = load_payload(source, project.root)
          observation = ObservationPolicy.metadata(payload)
          alive = alive_ids_from_payload(graph, payload).map do |node_id|
            node = graph.nodes.lookup(node_id).node
            details = node ? "Coverband executed #{node.file}:#{node.line}" : "Coverband marked #{node_id} as executed"
            AliveEvidence.new(
              node_id: node_id,
              evidence: evidence(kind: :alive, details: details, metadata: observation)
            )
          end

          AnalyzerResult.new(
            edge_evidences: [],
            alive_evidences: alive,
            uncertainties: {},
            observation: { 'coverband' => observation }
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :coverband,
            kind: :dynamic,
            soundness: :observational,
            description: 'Imports file and line execution data compatible with coverband-style exports.'
          )
        end

        private

        attr_reader :config

        def load_payload(source, root)
          return load_redis_payload(source) if source.start_with?('redis://', 'rediss://')

          path = File.expand_path(source, root)
          raise Error, "Coverband source does not exist: #{path}" unless File.file?(path)

          case File.extname(path)
          when '.json'
            JSON.parse(File.read(path))
          else
            YAML.safe_load_file(path, aliases: true) || {}
          end
        rescue JSON::ParserError, Psych::Exception => e
          raise Error, "Could not parse Coverband source #{path}: #{e.message}"
        end

        def load_redis_payload(source)
          RedisPayloadLoader.new(source: source, config: config).load
        end

        def alive_ids_from_payload(graph, payload)
          executed_nodes = Array(payload['executed'] || payload['nodes'])

          files = coverage_files(payload)
          by_line = graph.method_nodes.select do |node|
            executed_lines = lines_for(files, node.file)
            executed_lines.any? { |line| line.between?(node.line, node.end_line) }
          end

          (executed_nodes + by_line.map(&:graph_id)).uniq
        end

        def coverage_files(payload)
          candidates = %w[files coverage runtime production].filter_map { |key| payload[key] }
          candidates << payload if candidates.empty? && file_coverage_map?(payload)

          candidates.reduce({}) do |merged, candidate|
            merge_line_maps(merged, normalize_file_map(candidate))
          end
        end

        def file_coverage_map?(value)
          value.is_a?(Hash) && value.any? do |key, child|
            key.to_s.end_with?('.rb') || key.to_s.include?('/') || line_coverage?(child)
          end
        end

        def normalize_file_map(value)
          return {} unless value.is_a?(Hash)
          return normalize_file_map(value['files']) if value.is_a?(Hash) && value['files'].is_a?(Hash)

          value.each_with_object({}) do |(file, lines), normalized|
            next unless line_coverage?(lines)

            normalized[file.to_s] = executed_line_numbers(lines)
          end
        end

        def line_coverage?(value)
          value.is_a?(Array) || value.is_a?(Hash)
        end

        def executed_line_numbers(value)
          case value
          when Hash
            line_hash = value['lines'] || value[:lines] || value['coverage'] || value[:coverage]
            return executed_line_numbers(line_hash) if line_hash

            value.filter_map { |line, count| line.to_i if positive_integer?(count) }
          when Array
            return value.map(&:to_i).select(&:positive?).uniq if value.all? { |item| positive_integer?(item) }

            value.each_with_index.filter_map { |count, index| index + 1 if positive_integer?(count) }
          else
            []
          end
        end

        def positive_integer?(value)
          Integer(value, exception: false)&.positive?
        end

        def merge_line_maps(left, right)
          left.merge(right) { |_file, left_lines, right_lines| (left_lines + right_lines).uniq }
        end

        def lines_for(files, relative_file)
          exact = files[relative_file] || files[File.join('.', relative_file)]
          return exact if exact

          files.each do |file, lines|
            return lines if file.end_with?("/#{relative_file}")
          end

          []
        end
      end
    end
  end
end
