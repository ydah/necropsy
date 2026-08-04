# frozen_string_literal: true

require 'json'
require 'uri'
require 'yaml'

require_relative 'coverband_payload_set'
require_relative 'redis_input_limits'
require_relative 'redis_transport'

module Necropsy
  module Analyzers
    module Dynamic
      class RedisPayloadLoader
        DEFAULT_PATTERN = 'coverband*'

        def initialize(source:, config:)
          @redactor = RedisCredentialRedactor.new(source)
          @uri = parse_uri(source)
          @config = config
          @limits = RedisInputLimits.new(config)
        end

        def load
          start_session
          transport.connect
          authenticate
          select_database
          payload_processor.merge(keys.filter_map { |key| payload_for_key(key) })
        rescue RedisCommandError, Error => e
          raise Error, redactor.redact(e.message), cause: nil
        rescue StandardError => e
          raise Error, redactor.redact("Could not load Redis coverage: #{e.message}"), cause: nil
        ensure
          transport&.close
        end

        private

        attr_reader :uri, :config, :limits, :redactor, :transport, :deadline, :payload_processor

        def parse_uri(source)
          parsed = URI(source)
          return parsed if %w[redis rediss].include?(parsed.scheme) && parsed.host

          raise Error, 'Invalid Redis source URI'
        rescue URI::Error, ArgumentError
          raise Error, 'Invalid Redis source URI', cause: nil
        end

        def start_session
          @deadline = RedisDeadline.new(limits.total_timeout)
          @payload_processor = CoverbandPayloadSet.new(limits: limits, deadline: deadline)
          @transport = RedisTransport.new(uri: uri, limits: limits, deadline: deadline, redactor: redactor)
        end

        def authenticate
          return unless uri.password

          password = URI.decode_www_form_component(uri.password)
          return command('AUTH', password) unless uri.user

          command('AUTH', URI.decode_www_form_component(uri.user), password)
        end

        def select_database
          database = uri.path.to_s.delete_prefix('/')
          command('SELECT', database) unless database.empty?
        end

        def keys
          configured = Array(config['keys'] || config['key'] || query['key']).compact
          return validate_key_count!(configured) unless configured.empty?

          scan(pattern: config['pattern'] || query['pattern'] || DEFAULT_PATTERN)
        end

        def query
          @query ||= URI.decode_www_form(uri.query.to_s).to_h
        end

        def scan(pattern:)
          cursor = '0'
          found = []
          loop do
            deadline.check!
            cursor, batch = scan_page(cursor, pattern)
            append_keys!(found, batch)
            break if cursor == '0'
          end
          found
        end

        def scan_page(cursor, pattern)
          response = command('SCAN', cursor, 'MATCH', pattern)
          valid = response.is_a?(Array) && response.length == 2 && response.last.is_a?(Array)
          raise Error, 'Malformed Redis SCAN response' unless valid

          next_cursor = response.first.to_s
          raise Error, 'Malformed Redis SCAN cursor' unless next_cursor.match?(/\A\d+\z/)

          [next_cursor, response.last]
        end

        def append_keys!(found, batch)
          raise Error, 'Redis key count exceeds configured limit' if found.length + batch.length > limits.max_keys

          found.concat(batch)
        end

        def validate_key_count!(keys)
          raise Error, 'Redis key count exceeds configured limit' if keys.length > limits.max_keys

          keys
        end

        def payload_for_key(key)
          value = command('GET', key)
          return nil if value.nil? || value.empty?

          payload = parse_payload(value)
          raise Error, 'Redis coverage payload must be a mapping' unless payload.is_a?(Hash)

          limits.validate_payload!(payload)
        rescue RedisCommandError => e
          raise unless e.message.start_with?('WRONGTYPE')

          parse_hash_payload(command('HGETALL', key))
        end

        def command(*parts)
          transport.command(*parts)
        end

        def parse_payload(value)
          return nil if value.nil? || value.empty?

          parsed = begin
            JSON.parse(value, max_nesting: limits.max_payload_depth)
          rescue JSON::ParserError
            parse_yaml_payload(value)
          end
          limits.validate_payload!(parsed)
        end

        def parse_yaml_payload(value)
          YAML.safe_load(value, aliases: false)
        rescue Psych::Exception, ArgumentError, EncodingError, SystemStackError => e
          raise Error, redactor.redact("Invalid Redis coverage payload: #{e.message}"), cause: nil
        end

        def parse_hash_payload(entries)
          active_payload_processor.from_hash_entries(entries) { |value| parse_payload(value) }
        end

        def active_payload_processor
          @active_payload_processor ||= CoverbandPayloadSet.new(
            limits: limits,
            deadline: (@deadline ||= RedisDeadline.new(limits.total_timeout))
          )
        end
      end
    end
  end
end
