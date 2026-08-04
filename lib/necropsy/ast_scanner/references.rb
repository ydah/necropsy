# frozen_string_literal: true

module Necropsy
  class AstScanner
    RESPOND_TO_TRUTHY_LITERAL_TYPES = %i[
      array_node float_node hash_node imaginary_node integer_node
      interpolated_match_last_line_node interpolated_regular_expression_node
      interpolated_string_node interpolated_symbol_node interpolated_x_string_node
      keyword_hash_node match_last_line_node range_node rational_node
      regular_expression_node source_encoding_node source_file_node source_line_node
      string_node symbol_node true_node x_string_node
    ].freeze

    private

    def callback_names(node)
      names = symbol_arguments(node)
      with = keyword_value(node, 'with')
      names << with if with.is_a?(String)
      names.uniq
    end

    def custom_validator_names(node)
      keyword_keys(node).reject { |name| RAILS_BUILTIN_VALIDATORS.include?(name) }.map do |name|
        name.split('_').map(&:capitalize).join
      end
    end

    def delegated_method_name(name, target, prefix)
      return name unless prefix

      prefix_name = prefix == true ? target.to_s.delete_prefix('@') : prefix.to_s
      "#{prefix_name}_#{name}"
    end

    def record_delegate_target(caller_id, target, node, context)
      record_reference_call(caller_id, target.to_s.delete_prefix('@'), node, context, receiver_kind: :self)
    end

    def record_delegated_message(caller_id, message, node, context)
      record_reference_call(caller_id, message, node, context, receiver_kind: :unknown)
    end

    def record_symbol_reference(node, context)
      return unless SYMBOL_REFERENCE_CALLS.include?(node.name)

      message = first_symbol_argument(node) || first_string_argument(node)
      return unless message

      receiver = classify_receiver(node.receiver, context)
      record_reference_call(
        context.current_caller_id,
        message,
        node,
        context,
        receiver_kind: receiver[:kind],
        receiver_name: receiver[:name],
        candidates: receiver[:candidates],
        metadata: symbol_reference_metadata(node)
      )
    end

    def record_symbol_to_proc(node, context)
      block = node.block
      return unless block.is_a?(Prism::BlockArgumentNode)
      return unless block.expression.is_a?(Prism::SymbolNode)

      record_reference_call(
        context.current_caller_id,
        block.expression.unescaped.to_s,
        node,
        context,
        receiver_kind: :unknown
      )
    end

    def record_reference_call(caller_id, message, node, context, receiver_kind:, receiver_name: nil, candidates: [],
                              metadata: {})
      call_sites << CallSite.new(
        caller_id: caller_id,
        message: message.to_s,
        receiver_kind: receiver_kind,
        receiver_name: receiver_name,
        file: context.relative_file,
        line: node.location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'symbol_reference' => true, 'receiver_candidates' => Array(candidates) }.merge(metadata)
      )
    end

    def symbol_reference_metadata(node)
      metadata = { 'original_message' => node.name.to_s }
      return metadata unless node.name == :respond_to?

      metadata['include_private'] = respond_to_include_private(arguments(node))
      metadata
    end

    def respond_to_include_private(call_arguments)
      return false unless call_arguments.length > 1

      argument = call_arguments[1]
      return false if %i[false_node nil_node].include?(argument.type)
      return true if RESPOND_TO_TRUTHY_LITERAL_TYPES.include?(argument.type)

      'unknown'
    end
  end
end
