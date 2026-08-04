# frozen_string_literal: true

require 'uri'

module Necropsy
  module Analyzers
    module Dynamic
      class RedisInputLimits
        DEFAULTS = {
          'connect_timeout' => 5.0,
          'read_timeout' => 5.0,
          'total_timeout' => 15.0,
          'max_response_bytes' => 16 * 1024 * 1024,
          'max_bulk_bytes' => 8 * 1024 * 1024,
          'max_array_elements' => 100_000,
          'max_resp_depth' => 16,
          'max_keys' => 1_000,
          'max_payload_depth' => 64
        }.freeze
        TIMEOUT_KEYS = %w[connect_timeout read_timeout total_timeout].freeze
        INTEGER_KEYS = (DEFAULTS.keys - TIMEOUT_KEYS).freeze

        attr_reader(*DEFAULTS.keys.map(&:to_sym))

        def initialize(config)
          TIMEOUT_KEYS.each { |key| instance_variable_set("@#{key}", positive_float(config, key)) }
          INTEGER_KEYS.each { |key| instance_variable_set("@#{key}", positive_integer(config, key)) }
        end

        def validate_payload!(payload)
          stack = [[payload, 0]]
          until stack.empty?
            value, depth = stack.pop
            raise Error, 'Redis coverage payload exceeds maximum nesting depth' if depth > max_payload_depth
            if (value.is_a?(Hash) || value.is_a?(Array)) && value.length > max_array_elements
              raise Error, 'Redis coverage payload exceeds maximum collection size'
            end

            children = value.is_a?(Hash) ? value.flat_map { |key, child| [key, child] } : Array(value)
            stack.concat(children.map { |child| [child, depth + 1] }) if value.is_a?(Hash) || value.is_a?(Array)
          end
          payload
        end

        private

        def positive_float(config, key)
          value = Float(config.fetch(key, DEFAULTS.fetch(key)))
          return value if value.positive? && value.finite?

          invalid_limit!(key)
        rescue ArgumentError, TypeError
          invalid_limit!(key)
        end

        def positive_integer(config, key)
          value = Integer(config.fetch(key, DEFAULTS.fetch(key)))
          return value if value.positive?

          invalid_limit!(key)
        rescue ArgumentError, TypeError
          invalid_limit!(key)
        end

        def invalid_limit!(key)
          raise Error, "analyzers.dynamic.coverband.#{key} must be a finite positive number"
        end
      end

      class RedisDeadline
        def initialize(seconds)
          @expires_at = monotonic_time + seconds
        end

        def remaining
          seconds = @expires_at - monotonic_time
          raise Error, 'Redis total timeout exceeded' unless seconds.positive?

          seconds
        end

        def check!
          remaining
          nil
        end

        private

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      class RedisCredentialRedactor
        REDACTED = '[REDACTED]'

        def initialize(source)
          @source = source.to_s
          @safe_source = @source.sub(%r{(?<=://)[^/@\s]+@}, "#{REDACTED}@")
          @secrets = credentials(@source)
        end

        def redact(message)
          sanitized = message.to_s.gsub(@source, @safe_source)
          @secrets.reduce(sanitized) { |text, secret| text.gsub(secret, REDACTED) }
        end

        private

        def credentials(source)
          uri = URI(source)
          [uri.user, uri.password].compact.flat_map do |credential|
            [credential, URI.decode_www_form_component(credential)]
          end.reject(&:empty?).uniq.sort_by { |value| -value.length }
        rescue URI::Error, ArgumentError
          []
        end
      end
    end
  end
end
