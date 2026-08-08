# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Dynamic
      class CoverbandPayloadSet
        PAYLOAD_KEYS = %w[files coverage runtime production nodes executed observation].freeze

        def initialize(limits:, deadline:)
          @limits = limits
          @deadline = deadline
        end

        def merge(payloads)
          payloads.compact.reduce({}) do |merged, payload|
            validate_payload_hash!(payload)
            deadline.check!
            limits.validate_payload!(merge_payload(merged, payload))
          end
        end

        def from_hash_entries(entries, &)
          domain_error('Malformed Redis hash response') unless entries.is_a?(Array) && entries.length.even?

          hash = entries.each_slice(2).to_h
          return coverband_hash_payload(hash) if coverband_hash_payload?(hash)

          generic_hash_payload(hash, &)
        end

        def payload_shape?(value)
          value.is_a?(Hash) && value.keys.any? { |key| PAYLOAD_KEYS.include?(key.to_s) }
        end

        private

        attr_reader :limits, :deadline

        def generic_hash_payload(hash)
          payloads = []
          files = {}
          hash.each do |field, value|
            deadline.check!
            parsed = yield(value)
            if payload_shape?(parsed)
              payloads << parsed
            elsif parsed.is_a?(Hash) || parsed.is_a?(Array)
              files[field.to_s] = parsed
            else
              domain_error('Invalid Redis coverage payload value')
            end
          end

          payloads << { 'files' => files } unless files.empty?
          merge(payloads)
        end

        def coverband_hash_payload?(hash)
          hash.key?('file') && hash.key?('file_length')
        end

        def coverband_hash_payload(hash)
          payload = {
            'files' => { hash.fetch('file') => coverband_line_counts(hash) },
            'observation' => coverband_observation(hash)
          }
          limits.validate_payload!(payload)
        end

        def coverband_line_counts(hash)
          length = Integer(hash.fetch('file_length'), exception: false)
          domain_error('Invalid Coverband file length') unless length && length >= 0
          domain_error('Coverband file length exceeds configured limit') if length > limits.max_array_elements

          Array.new(length) do |index|
            deadline.check!
            count = hash[index.to_s]
            count&.to_i
          end
        end

        def coverband_observation(hash)
          %w[first_updated_at last_updated_at file_hash].each_with_object({}) do |key, observation|
            observation[key] = hash[key] if hash[key]
          end
        end

        def validate_payload_hash!(payload)
          domain_error('Redis coverage payload must be a mapping') unless payload.is_a?(Hash)

          limits.validate_payload!(payload)
        end

        def merge_payload(merged, payload)
          merged.merge(payload) do |key, left, right|
            case key.to_s
            when 'files', 'coverage', 'runtime', 'production' then merge_files(left, right)
            when 'nodes', 'executed' then (Array(left) + Array(right)).uniq
            when 'edges' then Array(left) + Array(right)
            when 'observation' then ObservationPolicy.compatible_merge(left, right)
            else right
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
          domain_error('Merged Redis coverage exceeds configured collection size') if length > limits.max_array_elements

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

        def domain_error(message)
          raise Error, message
        end
      end
    end
  end
end
