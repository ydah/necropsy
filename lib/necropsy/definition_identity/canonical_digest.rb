# frozen_string_literal: true

require 'digest'
require 'json'

module Necropsy
  module DefinitionIdentity
    class CanonicalizationError < StandardError; end
    class LimitExceeded < CanonicalizationError; end
    class CycleError < CanonicalizationError; end
    class UnsupportedTypeError < CanonicalizationError; end

    class CanonicalDigest
      MAX_DEPTH = 256
      MAX_ITEMS = 1_000_000
      MAX_SCALAR_BYTES = 64 * 1024 * 1024
      MAX_TOTAL_BYTES = 256 * 1024 * 1024

      def initialize(max_depth: MAX_DEPTH, max_items: MAX_ITEMS, max_scalar_bytes: MAX_SCALAR_BYTES,
                     max_total_bytes: MAX_TOTAL_BYTES)
        @max_depth = positive_limit(max_depth, :max_depth)
        @max_items = positive_limit(max_items, :max_items)
        @max_scalar_bytes = positive_limit(max_scalar_bytes, :max_scalar_bytes)
        @max_total_bytes = positive_limit(max_total_bytes, :max_total_bytes)
      end

      def hexdigest(value)
        reset_state
        output = DigestOutput.new(byte_budget)
        process([[:value, value, 0, output]])
        output.hexdigest
      end

      def hexdigest_payload(values)
        reset_state
        output = DigestOutput.new(byte_budget)
        output.write('[')
        values.each_with_index do |value, index|
          count_item!
          output.write(',') if index.positive?
          output.write(payload_scalar(value))
        end
        output.write(']')
        output.hexdigest
      end

      private

      attr_reader :max_depth, :max_items, :max_scalar_bytes, :max_total_bytes, :active_containers, :byte_budget

      def reset_state
        @active_containers = {}
        @items = 0
        @byte_budget = ByteBudget.new(max_total_bytes)
      end

      def process(stack)
        until stack.empty?
          action, *arguments = stack.pop
          send("process_#{action}", stack, *arguments)
        end
      rescue CanonicalizationError
        raise
      rescue SystemStackError => e
        raise CanonicalizationError, "Could not canonicalize definition: #{e.message}"
      rescue StandardError => e
        raise CanonicalizationError, "Could not canonicalize definition: #{e.class}: #{e.message}"
      end

      def process_value(stack, value, depth, output)
        count_item!
        check_depth!(depth)
        case value
        when Prism::Node then start_node(stack, value, depth, output)
        when Prism::Location then output.write('null')
        when Array then start_array(stack, value, depth, output)
        when Hash then start_hash(stack, value, depth, output)
        when Symbol then tagged_scalar(output, 'symbol', value.to_s)
        when String then tagged_scalar(output, 'string', value)
        when Integer then tagged_scalar(output, 'integer', value.to_s)
        when Float then write_float(output, value)
        when true, false then output.write(%(["boolean",#{value}]))
        when nil then output.write('["nil"]')
        else raise UnsupportedTypeError, "Unsupported definition payload type: #{value.class}"
        end
      end

      def start_node(stack, node, depth, output)
        enter_container!(node)
        fields = node.deconstruct_keys(nil).filter_map do |key, value|
          [key.to_s, value] unless DefinitionIdentity.send(:excluded_key?, key)
        end.sort_by(&:first)
        type = checked_string(node.type.to_s)
        flags = node.send(:flags) & ~Prism::NodeFlags::NEWLINE
        output.write("[\"node\",#{json_string(type)},#{flags},[")
        stack << [:node_field, node, fields, 0, depth, output]
      end

      def process_node_field(stack, node, fields, index, depth, output)
        if index >= fields.length
          output.write(']]')
          leave_container(node)
          return
        end

        key, value = fields.fetch(index)
        output.write(',') if index.positive?
        output.write("[#{json_string(checked_string(key))},")
        stack << [:node_field_complete, node, fields, index, depth, output]
        stack << [:value, value, depth + 1, output]
      end

      def process_node_field_complete(stack, node, fields, index, depth, output)
        output.write(']')
        stack << [:node_field, node, fields, index + 1, depth, output]
      end

      def start_array(stack, value, depth, output)
        enter_container!(value)
        output.write('["array",[')
        stack << [:array_next, value, 0, depth, output]
      end

      def process_array_next(stack, value, index, depth, output)
        if index >= value.length
          output.write(']]')
          leave_container(value)
          return
        end

        output.write(',') if index.positive?
        stack << [:array_next, value, index + 1, depth, output]
        stack << [:value, value.fetch(index), depth + 1, output]
      end

      def start_hash(stack, value, depth, output)
        enter_container!(value)
        stack << [:hash_next, value, value.each_pair, [], depth, output]
      end

      def process_hash_next(stack, value, iterator, pairs, depth, output)
        key, item = iterator.next
        pair = StringOutput.new(byte_budget)
        pair.write('[')
        stack << [:hash_pair_complete, value, iterator, pairs, depth, output, pair]
        stack << [:raw, pair, ']']
        stack << [:value, item, depth + 1, pair]
        stack << [:raw, pair, ',']
        stack << [:value, key, depth + 1, pair]
      rescue StopIteration
        output.write('["hash",[')
        pairs.sort.each_with_index do |pair, index|
          output.write(',') if index.positive?
          output.write(pair)
        end
        output.write(']]')
        leave_container(value)
      end

      def process_hash_pair_complete(stack, value, iterator, pairs, depth, output, pair)
        pairs << pair.to_s
        stack << [:hash_next, value, iterator, pairs, depth, output]
      end

      def process_raw(_stack, output, bytes)
        output.write(bytes)
      end

      def tagged_scalar(output, tag, value)
        output.write(%([#{json_string(tag)},#{json_string_or_fingerprint(value)}]))
      end

      def write_float(output, value)
        raise UnsupportedTypeError, 'Definition payload contains a non-finite float' unless value.finite?

        tagged_scalar(output, 'float', value.to_s)
      end

      def payload_scalar(value)
        case value
        when String then json_string_or_fingerprint(value)
        when Integer then value.to_s
        else raise UnsupportedTypeError, "Unsupported definition identity component: #{value.class}"
        end
      end

      def json_string_or_fingerprint(value)
        checked_string(value)
        JSON.generate(value)
      rescue JSON::GeneratorError, EncodingError
        JSON.generate(['invalid_string', value.encoding.name, value.bytesize, Digest::SHA256.hexdigest(value.b)])
      end

      def json_string(value)
        JSON.generate(value)
      end

      def checked_string(value)
        return value if value.bytesize <= max_scalar_bytes

        raise LimitExceeded, "Canonical scalar exceeds maximum size #{max_scalar_bytes}"
      end

      def enter_container!(value)
        object_id = value.object_id
        raise CycleError, "Definition payload contains a cycle at #{value.class}" if active_containers.key?(object_id)

        active_containers[object_id] = true
      end

      def leave_container(value)
        active_containers.delete(value.object_id)
      end

      def check_depth!(depth)
        return if depth <= max_depth

        raise LimitExceeded, "Canonical payload exceeds maximum depth #{max_depth}"
      end

      def count_item!
        @items += 1
        raise LimitExceeded, "Canonical payload exceeds maximum item count #{max_items}" if @items > max_items
      end

      def positive_limit(value, name)
        value = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless value.positive?

        value
      end

      class DigestOutput
        def initialize(budget)
          @budget = budget
          @digest = Digest::SHA256.new
        end

        def write(value)
          @budget.consume(value.bytesize)
          @digest.update(value.b)
        end

        def hexdigest
          @digest.hexdigest
        end
      end

      class StringOutput
        def initialize(budget)
          @budget = budget
          @value = String.new(encoding: Encoding::BINARY)
        end

        def write(value)
          @budget.consume(value.bytesize)
          @value << value.b
        end

        def to_s
          @value
        end
      end

      class ByteBudget
        def initialize(limit)
          @limit = limit
          @bytes = 0
        end

        def consume(bytes)
          @bytes += bytes
          raise LimitExceeded, "Canonical payload exceeds maximum size #{@limit}" if @bytes > @limit
        end
      end
    end
  end
end
