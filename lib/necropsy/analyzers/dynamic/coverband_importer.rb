# frozen_string_literal: true

require 'json'
require 'openssl'
require 'socket'
require 'uri'
require 'yaml'

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
          alive = alive_from_payload(graph, payload).map do |node|
            AliveEvidence.new(
              node_id: node.id,
              evidence: evidence(kind: :alive, details: "Coverband executed #{node.file}:#{node.line}",
                                 metadata: payload['observation'] || {})
            )
          end

          AnalyzerResult.new(
            edge_evidences: [],
            alive_evidences: alive,
            uncertainties: {},
            observation: { 'coverband' => payload['observation'] || {} }
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
          case File.extname(path)
          when '.json'
            JSON.parse(File.read(path))
          else
            YAML.load_file(path) || {}
          end
        end

        def load_redis_payload(source)
          RedisPayloadLoader.new(source: source, config: config).load
        end

        def alive_from_payload(graph, payload)
          executed_nodes = Array(payload['executed'] || payload['nodes'])
          by_id = executed_nodes.filter_map { |id| graph.nodes[id] }

          files = coverage_files(payload)
          by_line = graph.method_nodes.select do |node|
            executed_lines = lines_for(files, node.file)
            executed_lines.any? { |line| line.between?(node.line, node.end_line) }
          end

          (by_id + by_line).uniq(&:id)
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

      class RedisPayloadLoader
        DEFAULT_PATTERN = 'coverband*'

        def initialize(source:, config:)
          @uri = URI(source)
          @config = config
          @socket = nil
        end

        def load
          connect
          authenticate
          select_database
          merge_payloads(keys.filter_map { |key| payload_for_key(key) })
        ensure
          socket&.close
        end

        private

        attr_reader :uri, :config, :socket

        def connect
          tcp_socket = TCPSocket.new(uri.host, uri.port || 6379)
          @socket = uri.scheme == 'rediss' ? tls_socket(tcp_socket) : tcp_socket
        end

        def tls_socket(tcp_socket)
          context = OpenSSL::SSL::SSLContext.new
          socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
          socket.hostname = uri.host if socket.respond_to?(:hostname=)
          socket.connect
          socket
        end

        def authenticate
          return unless uri.password

          command('AUTH', uri.password)
        end

        def select_database
          db = uri.path.to_s.delete_prefix('/')
          command('SELECT', db) unless db.empty?
        end

        def keys
          configured = Array(config['keys'] || config['key'] || query['key']).compact
          return configured unless configured.empty?

          scan(pattern: config['pattern'] || query['pattern'] || DEFAULT_PATTERN)
        end

        def query
          @query ||= URI.decode_www_form(uri.query.to_s).to_h
        end

        def scan(pattern:)
          cursor = '0'
          found = []
          loop do
            cursor, keys = command('SCAN', cursor, 'MATCH', pattern)
            found.concat(keys)
            break if cursor == '0'
          end
          found
        end

        def command(*parts)
          socket.write(redis_command(parts))
          read_response
        end

        def payload_for_key(key)
          parse_payload(command('GET', key))
        rescue Error => e
          raise unless e.message.include?('WRONGTYPE')

          parse_hash_payload(command('HGETALL', key))
        end

        def redis_command(parts)
          ["*#{parts.length}", *parts.flat_map { |part| ["$#{part.to_s.bytesize}", part.to_s] }].join("\r\n") + "\r\n"
        end

        def read_response
          prefix = socket.read(1)
          case prefix
          when '+'
            socket.gets("\r\n").delete_suffix("\r\n")
          when '-'
            raise Error, socket.gets("\r\n").delete_suffix("\r\n")
          when ':'
            socket.gets("\r\n").to_i
          when '$'
            read_bulk_string
          when '*'
            Array.new(socket.gets("\r\n").to_i) { read_response }
          else
            raise Error, "Unsupported Redis response prefix #{prefix.inspect}"
          end
        end

        def read_bulk_string
          length = socket.gets("\r\n").to_i
          return nil if length.negative?

          value = socket.read(length)
          socket.read(2)
          value
        end

        def parse_payload(value)
          return nil if value.nil? || value.empty?

          JSON.parse(value)
        rescue JSON::ParserError
          YAML.load(value)
        rescue Psych::SyntaxError
          Marshal.load(value)
        end

        def parse_hash_payload(entries)
          hash = Array(entries).each_slice(2).to_h
          return coverband_hash_payload(hash) if coverband_hash_payload?(hash)

          payloads = []
          files = {}
          hash.each do |field, value|
            parsed = parse_payload(value)
            if payload_shape?(parsed)
              payloads << parsed
            else
              files[field.to_s] = parsed
            end
          end

          payloads << { 'files' => files } unless files.empty?
          merge_payloads(payloads)
        end

        def coverband_hash_payload?(hash)
          hash.key?('file') && hash.key?('file_length')
        end

        def coverband_hash_payload(hash)
          {
            'files' => { hash.fetch('file') => coverband_line_counts(hash) },
            'observation' => coverband_observation(hash)
          }
        end

        def coverband_line_counts(hash)
          length = hash.fetch('file_length').to_i
          Array.new(length) do |index|
            count = hash[index.to_s]
            count&.to_i
          end
        end

        def coverband_observation(hash)
          %w[first_updated_at last_updated_at file_hash].each_with_object({}) do |key, observation|
            observation[key] = hash[key] if hash[key]
          end
        end

        def payload_shape?(value)
          value.is_a?(Hash) && value.keys.any? do |key|
            %w[files coverage runtime production nodes executed observation].include?(key.to_s)
          end
        end

        def merge_payloads(payloads)
          payloads.compact.reduce({}) { |merged, payload| merge_payload(merged, payload) }
        end

        def merge_payload(merged, payload)
          merged.merge(payload) do |key, left, right|
            case key
            when 'files', 'coverage', 'runtime', 'production'
              merge_files(left, right)
            when 'nodes', 'executed'
              (Array(left) + Array(right)).uniq
            when 'edges'
              Array(left) + Array(right)
            when 'observation'
              left.merge(right)
            else
              right
            end
          end
        end

        def merge_files(left, right)
          return right unless left.is_a?(Hash)
          return left unless right.is_a?(Hash)

          left.merge(right) do |_file, left_lines, right_lines|
            merge_file_coverage(left_lines, right_lines)
          end
        end

        def merge_file_coverage(left, right)
          return merge_count_hashes(left, right) if left.is_a?(Hash) && right.is_a?(Hash)
          return merge_count_arrays(left, right) if count_array?(left) || count_array?(right)

          (Array(left) + Array(right)).uniq
        end

        def merge_count_hashes(left, right)
          left.merge(right) { |_line, left_count, right_count| left_count.to_i + right_count.to_i }
        end

        def merge_count_arrays(left, right)
          length = [Array(left).length, Array(right).length].max
          Array.new(length) do |index|
            left_value = Array(left)[index]
            right_value = Array(right)[index]
            next if left_value.nil? && right_value.nil?

            left_value.to_i + right_value.to_i
          end
        end

        def count_array?(value)
          value.is_a?(Array) && value.any? { |item| item.nil? || item.to_i.zero? }
        end
      end
    end
  end
end
