# frozen_string_literal: true

require 'json'
require 'yaml'

require_relative 'redis_payload_loader'
require_relative 'runtime_reference'

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
          observation = ObservationPolicy.metadata(payload, expected_revision: config['expected_source_revision'])
          node_ids, line_diagnostics = alive_ids_from_payload(graph, payload)
          observation = observation.merge(line_diagnostics) unless line_diagnostics.empty?
          alive = node_ids.map do |node_id|
            node = graph.nodes.lookup(node_id).node
            details = node ? "Coverband executed #{node.file}:#{node.line}" : "Coverband marked #{node_id} as executed"
            AliveEvidence.new(
              node_id: node_id,
              evidence: evidence(
                kind: :alive,
                details: details,
                metadata: observation.merge('node_reference' => node_id),
                grade: :observed,
                relation: :execution,
                source: { 'type' => 'coverband', 'node_reference' => node_id },
                scope: ObservationPolicy.evidence_scope(observation).merge('node_reference' => node_id)
              )
            )
          end

          AnalyzerResult.new(
            edge_evidences: [],
            alive_evidences: alive,
            uncertainties: {},
            observation: { 'coverband' => observation },
            resolutions: [],
            evidences: result_evidences(alive)
          )
        end

        def profile
          AnalyzerProfile.new(
            name: :coverband,
            kind: :dynamic,
            soundness: :observational,
            description: 'Imports file and line execution data compatible with coverband-style exports.',
            version: Necropsy::VERSION,
            assumptions: %w[line_execution_mapping positive_observations_only]
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
          structured = payload['node_references'] if payload.key?('node_references')
          malformed = []
          executed_nodes = RuntimeReference.preferred(
            structured: structured,
            legacy: payload['executed'] || payload['nodes']
          ).map do |reference|
            normalized = RuntimeReference.normalize(reference)
            next normalized if normalized

            malformed << { 'kind' => 'node', 'reference' => reference }
            reference
          end

          files = coverage_files(payload)
          by_line, diagnostics = line_references(graph, files)
          diagnostics['malformed_references'] = malformed unless malformed.empty?

          [(executed_nodes + by_line).uniq, diagnostics]
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

        def line_references(graph, files)
          definition_ids = []
          line_ambiguities = []
          path_ambiguities = []
          graph.method_nodes.group_by(&:file).sort.each do |relative_file, definitions|
            paths = matching_coverage_paths(files, relative_file)
            next if paths.empty?

            path_ambiguities << { 'file' => relative_file, 'coverage_paths' => paths } if paths.length > 1
            paths.flat_map { |path| files.fetch(path) }.uniq.sort.each do |line|
              matches = definitions.select { |definition| line.between?(definition.line, definition.end_line) }
              definition_ids.concat(matches.map(&:graph_id))
              next unless matches.length > 1

              line_ambiguities << {
                'file' => relative_file,
                'line' => line,
                'definition_ids' => matches.map(&:graph_id).sort
              }
            end
          end

          diagnostics = {}
          diagnostics['path_ambiguities'] = path_ambiguities unless path_ambiguities.empty?
          diagnostics['line_ambiguities'] = line_ambiguities unless line_ambiguities.empty?
          [definition_ids.uniq.sort, diagnostics]
        end

        def matching_coverage_paths(files, relative_file)
          exact = [relative_file, File.join('.', relative_file)].select { |path| files.key?(path) }
          return exact.sort unless exact.empty?

          suffix = "/#{relative_file}"
          files.keys.select { |path| path.end_with?(suffix) }.sort
        end
      end
    end
  end
end
