# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def handle_module_relation(node, context)
      return unless MODULE_RELATION_MACROS.include?(node.name)
      return unless context.owner

      class_record(context.owner)[:extends] << [context.owner] if node.name == :extend && arguments(node).any?(Prism::SelfNode)

      constants = arguments(node).filter_map { |argument| constant_name(argument) }
      return if constants.empty?

      data = class_record(context.owner)
      key = :"#{node.name}s"
      constants.each { |constant| data[key] << constant_candidates(constant, context.namespace) }
    end

    def handle_rails_callback(node, context)
      return unless context.owner
      return if context.test

      if RAILS_CALLBACK_MACROS.include?(node.name)
        callback_names(node).each do |method_name|
          entrypoint_hints << EntryPoint.new(node_id: "#{context.owner}##{method_name}", reason: :callback_registered)
        end
      elsif node.name == :validates
        custom_validator_names(node).each do |validator|
          constant_candidates("#{validator}Validator", context.namespace).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate_each", reason: :callback_registered)
          end
        end
      elsif node.name == :validates_with
        arguments(node).filter_map { |argument| constant_name(argument) }.each do |validator|
          constant_candidates(validator, context.namespace).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate", reason: :callback_registered)
          end
        end
      end
    end

    def handle_attr_macro(node, context)
      return false unless ATTR_MACROS.include?(node.name)
      return false unless context.owner

      symbol_arguments(node).each do |name|
        kind, separator = method_kind_and_separator(context)
        nodes << Node.new(
          id: "#{context.owner}#{separator}#{name}",
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: name,
          test: context.test,
          visibility: context.visibility
        )
        next unless %i[attr_writer attr_accessor].include?(node.name)

        nodes << Node.new(
          id: "#{context.owner}#{separator}#{name}=",
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: "#{name}=",
          test: context.test,
          visibility: context.visibility
        )
      end
      true
    end

    def handle_delegate(node, context)
      return false unless node.name == :delegate
      return false unless context.owner

      target = keyword_value(node, 'to')
      prefix = keyword_value(node, 'prefix')
      symbol_arguments(node).each do |name|
        generated_name = delegated_method_name(name, target, prefix)
        kind, separator = method_kind_and_separator(context)
        id = "#{context.owner}#{separator}#{generated_name}"
        nodes << Node.new(
          id: id,
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: :delegate,
          owner: context.owner,
          name: generated_name,
          test: context.test,
          visibility: context.visibility
        )
        record_delegate_target(id, target, node, context) if target
        record_delegated_message(id, name, node, context)
      end
      true
    end

    def handle_forwardable(node, context)
      return false unless %i[def_delegator def_delegators].include?(node.name)
      return false unless context.owner

      symbols = symbol_arguments(node)
      return false if symbols.length < 2

      target = symbols.shift
      definitions = if node.name == :def_delegator
                      [[symbols[1] || symbols[0], symbols[0]]]
                    else
                      symbols.map { |name| [name, name] }
                    end
      definitions.each do |generated_name, delegated_name|
        kind, separator = method_kind_and_separator(context)
        id = "#{context.owner}#{separator}#{generated_name}"
        nodes << Node.new(
          id: id,
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: generated_name,
          test: context.test,
          visibility: context.visibility
        )
        record_delegate_target(id, target, node, context)
        record_delegated_message(id, delegated_name, node, context)
      end
      true
    end
  end
end
