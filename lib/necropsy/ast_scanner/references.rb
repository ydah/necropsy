# frozen_string_literal: true

module Necropsy
  class AstScanner
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
        candidates: receiver[:candidates]
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

    def record_reference_call(caller_id, message, node, context, receiver_kind:, receiver_name: nil, candidates: [])
      call_sites << CallSite.new(
        caller_id: caller_id,
        message: message.to_s,
        receiver_kind: receiver_kind,
        receiver_name: receiver_name,
        file: context.relative_file,
        line: node.location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'symbol_reference' => true, 'receiver_candidates' => Array(candidates) }
      )
    end
  end
end
