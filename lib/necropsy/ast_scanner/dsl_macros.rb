# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def handle_module_relation(node, context)
      return unless MODULE_RELATION_MACROS.include?(node.name)
      return unless context.owner

      unless static_module_relation?(node, context)
        record_semantic_blocker(
          :dynamic_ancestry,
          node,
          context,
          "#{node.name} is not an unconditional load-time ancestry mutation",
          suggested_action: :make_ancestry_static,
          force_global: true
        )
        return
      end

      if node.name == :extend && arguments(node).any?(Prism::SelfNode)
        class_record(context.owner)[:extends] << [context.owner]
        class_record(context.owner)[:singleton_includes] << [context.owner]
      end

      dynamic_arguments = arguments(node).reject do |argument|
        constant_name(argument) || (node.name == :extend && argument.is_a?(Prism::SelfNode))
      end
      unless dynamic_arguments.empty?
        class_record(context.owner)[:dynamic] = true
        record_semantic_blocker(
          :dynamic_ancestry,
          node,
          context,
          "#{node.name} has a runtime-computed module and lookup cannot be closed",
          suggested_action: :make_ancestry_static
        )
      end

      constants = arguments(node).filter_map { |argument| constant_name(argument) }
      return if constants.empty?

      data = class_record(context.owner)
      key = module_relation_key(node.name, context)
      constants.reverse_each do |constant|
        candidates = constant_candidates(constant, context.namespace)
        data[key] << candidates
        data[:extends] << candidates if key == :singleton_includes && node.name == :extend
      end
    end

    def static_module_relation?(node, context)
      context.static_ancestry && node.receiver.nil?
    end

    def module_relation_key(name, context)
      return :singleton_includes if context.singleton_scope && name == :include
      return :singleton_prepends if context.singleton_scope && name == :prepend
      return :singleton_includes if name == :extend

      :"#{name}s"
    end

    def handle_rails_callback(node, context)
      return unless context.owner
      return if context.test

      if RAILS_CALLBACK_MACROS.include?(node.name)
        return if callback_disabled?(node)

        record_callback_condition_blocker(node, context) if callback_condition_unknown?(node)
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

    def callback_disabled?(node)
      condition = keyword_value(node, 'if')
      condition = !keyword_value(node, 'unless') if keyword_keys(node).include?('unless')
      (keyword_keys(node).include?('if') || keyword_keys(node).include?('unless')) && condition == false
    end

    def callback_condition_unknown?(node)
      keyword_keys(node).intersect?(%w[if unless]) &&
        keyword_value(node, 'if').nil? && keyword_value(node, 'unless').nil?
    end

    def record_callback_condition_blocker(node, context)
      record_semantic_blocker(
        :rails_callback_condition,
        node,
        context,
        'callback condition is not statically known',
        suggested_action: :review_callback_condition
      )
    end

    def handle_generated_rails_methods(node, context)
      return false unless %i[enum store_accessor belongs_to has_one has_many].include?(node.name)
      return false unless context.owner && !context.test && rails_framework_enabled?

      names = symbol_arguments(node)
      if names.empty?
        record_semantic_blocker(
          :rails_generated_methods,
          node,
          context,
          "#{node.name} has dynamic generated method names",
          suggested_action: :review_generated_methods
        )
        return true
      end

      case node.name
      when :enum
        enum_name = names.first
        enum_values = keyword_keys(node)
        add_generated_methods(context, [enum_name, "#{enum_name}=", *enum_values.map { |name| "#{name}?" }], node)
      when :store_accessor
        add_generated_methods(context, names.drop(1).flat_map { |name| [name, "#{name}="] }, node)
      else
        names.each do |name|
          add_generated_methods(context, [name, "#{name}=", "build_#{name}", "create_#{name}"], node)
        end
      end
      true
    end

    def rails_framework_enabled?
      project.config.frameworks.include?('rails') || project.config.rails_enabled?(reference_files: project.reference_files)
    rescue SystemCallError, EncodingError
      project.config.frameworks.include?('rails')
    end

    def add_generated_methods(context, names, source_node)
      names.uniq.each do |name|
        kind, separator = method_kind_and_separator(context)
        add_definition(
          symbol_id: "#{context.owner}#{separator}#{name}",
          kind: kind,
          source_node: source_node,
          context: context,
          defined_via: :rails_generated,
          owner: context.owner,
          name: name,
          visibility: :public
        )
      end
    end

    def handle_attr_macro(node, context)
      return false unless ATTR_MACROS.include?(node.name)
      return false unless context.owner

      symbol_arguments(node).each do |name|
        kind, separator = method_kind_and_separator(context)
        add_definition(
          symbol_id: "#{context.owner}#{separator}#{name}",
          kind: kind,
          source_node: node,
          context: context,
          defined_via: node.name,
          owner: context.owner,
          name: name,
          visibility: context.visibility
        )
        next unless %i[attr_writer attr_accessor].include?(node.name)

        add_definition(
          symbol_id: "#{context.owner}#{separator}#{name}=",
          kind: kind,
          source_node: node,
          context: context,
          defined_via: node.name,
          owner: context.owner,
          name: "#{name}=",
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
        definition = add_definition(
          symbol_id: id,
          kind: kind,
          source_node: node,
          context: context,
          defined_via: :delegate,
          owner: context.owner,
          name: generated_name,
          visibility: context.visibility
        )
        record_delegate_target(definition.graph_id, target, node, context) if target
        record_delegated_message(definition.graph_id, name, node, context)
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
        definition = add_definition(
          symbol_id: id,
          kind: kind,
          source_node: node,
          context: context,
          defined_via: node.name,
          owner: context.owner,
          name: generated_name,
          visibility: context.visibility
        )
        record_delegate_target(definition.graph_id, target, node, context)
        record_delegated_message(definition.graph_id, delegated_name, node, context)
      end
      true
    end
  end
end
