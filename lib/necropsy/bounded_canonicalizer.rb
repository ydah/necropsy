# frozen_string_literal: true

require 'json'

module Necropsy
  class BoundedCanonicalizer
    MAX_DEPTH = 256
    MAX_ITEMS = 1_000_000
    MAX_STRING_BYTES = 64 * 1024 * 1024
    MAX_TOTAL_BYTES = 256 * 1024 * 1024

    class Error < StandardError; end
    class CycleError < Error; end
    class LimitError < Error; end
    class UnsupportedTypeError < Error; end

    def self.dump(value, **limits)
      new(**limits).dump(value)
    end

    def initialize(max_depth: MAX_DEPTH, max_items: MAX_ITEMS, max_string_bytes: MAX_STRING_BYTES,
                   max_total_bytes: MAX_TOTAL_BYTES)
      @max_depth = positive_limit(max_depth, :max_depth)
      @max_items = positive_limit(max_items, :max_items)
      @max_string_bytes = positive_limit(max_string_bytes, :max_string_bytes)
      @max_total_bytes = positive_limit(max_total_bytes, :max_total_bytes)
    end

    # Kept for callers that need the canonical Ruby representation rather than bytes.
    def call(value)
      JSON.parse(dump(value), max_nesting: false)
    end

    def dump(value)
      reset_state
      output = binary_string
      process([[:value, value, 0, output]])
      output
    rescue JSON::GeneratorError => e
      raise Error, "Could not encode canonical payload: #{e.message}"
    end

    private

    attr_reader :max_depth, :max_items, :max_string_bytes, :max_total_bytes, :active_containers

    def reset_state
      @active_containers = {}
      @items = 0
    end

    def process(stack)
      until stack.empty?
        action, *arguments = stack.pop
        send("process_#{action}", stack, *arguments)
      end
    rescue SystemStackError => e
      raise CycleError, "Could not canonicalize payload: #{e.message}"
    end

    def process_value(stack, value, depth, output)
      count_item!
      check_depth!(depth)

      case value
      when Hash then start_hash(stack, value, depth, output)
      when Array then start_array(stack, value, depth, output)
      when Symbol then append(output, %(["symbol",#{encoded_string(canonical_string(value.to_s))}]))
      when String then append(output, %(["string",#{encoded_string(canonical_string(value))}]))
      when Integer then append(output, %(["integer",#{json_string(value.to_s)}]))
      when Float then append(output, %(["float",#{json_string(canonical_float(value))}]))
      when true, false then append(output, %(["boolean",#{value}]))
      when nil then append(output, '["nil"]')
      else start_object(stack, value, depth, output)
      end
    end

    def start_array(stack, value, depth, output)
      enter_container!(value)
      append(output, '["array",[')
      stack << [:array_next, value, 0, depth, output]
    end

    def process_array_next(stack, value, index, depth, output)
      if index >= value.length
        append(output, ']]')
        leave_container(value)
        return
      end

      append(output, ',') if index.positive?
      stack << [:array_next, value, index + 1, depth, output]
      stack << [:value, value.fetch(index), depth + 1, output]
    end

    def start_hash(stack, value, depth, output)
      enter_container!(value)
      stack << [:hash_next, value, value.each_pair, [], depth, output]
    end

    def process_hash_next(stack, value, iterator, pairs, depth, output)
      key, item = iterator.next
      pair = binary_string
      append(pair, '[')
      stack << [:hash_pair_complete, value, iterator, pairs, depth, output, pair]
      stack << [:raw, pair, ']']
      stack << [:value, item, depth + 1, pair]
      stack << [:raw, pair, ',']
      stack << [:value, key, depth + 1, pair]
    rescue StopIteration
      append(output, '["hash",[')
      pairs.sort.each_with_index do |pair, index|
        append(output, ',') if index.positive?
        append(output, pair)
      end
      append(output, ']]')
      leave_container(value)
    end

    def process_hash_pair_complete(stack, value, iterator, pairs, depth, output, pair)
      pairs << pair
      stack << [:hash_next, value, iterator, pairs, depth, output]
    end

    def start_object(stack, value, depth, output)
      raise UnsupportedTypeError, "Unsupported canonical payload type: #{value.class}" unless value.respond_to?(:to_h)

      enter_container!(value)
      converted = value.to_h
      append(output, %(["object",#{json_string(value.class.name.to_s)},))
      stack << [:object_complete, value, output]
      stack << [:value, converted, depth + 1, output]
    rescue Error
      raise
    rescue StandardError => e
      leave_container(value)
      raise UnsupportedTypeError, "Could not convert #{value.class} to a canonical payload: #{e.class}"
    end

    def process_object_complete(_stack, value, output)
      append(output, ']')
      leave_container(value)
    end

    def process_raw(_stack, output, bytes)
      append(output, bytes)
    end

    def encoded_string(value)
      %([#{json_string(value.fetch(0))},#{json_string(value.fetch(1))}])
    end

    def canonical_string(value)
      check_scalar_size!(value)
      normalized = value.encode(Encoding::UTF_8)
      ['UTF-8', normalized.b.unpack1('H*')]
    rescue EncodingError
      [value.encoding.name, value.b.unpack1('H*')]
    end

    def canonical_float(value)
      raise UnsupportedTypeError, 'Canonical payload contains a non-finite float' unless value.finite?

      value.to_s
    end

    def json_string(value)
      JSON.generate(value)
    end

    def append(output, bytes)
      size = output.bytesize + bytes.bytesize
      raise LimitError, "Canonical payload exceeds maximum size #{max_total_bytes}" if size > max_total_bytes

      output << bytes.b
    end

    def enter_container!(value)
      object_id = value.object_id
      raise CycleError, "Canonical payload contains a cycle at #{value.class}" if active_containers.key?(object_id)

      active_containers[object_id] = true
    end

    def leave_container(value)
      active_containers.delete(value.object_id)
    end

    def check_scalar_size!(value)
      return if value.bytesize <= max_string_bytes

      raise LimitError, "Canonical string exceeds maximum size #{max_string_bytes}"
    end

    def check_depth!(depth)
      return if depth <= max_depth

      raise LimitError, "Canonical payload exceeds maximum depth #{max_depth}"
    end

    def count_item!
      @items += 1
      raise LimitError, "Canonical payload exceeds maximum item count #{max_items}" if @items > max_items
    end

    def positive_limit(value, name)
      value = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless value.positive?

      value
    end

    def binary_string
      String.new(encoding: Encoding::BINARY)
    end
  end
end
