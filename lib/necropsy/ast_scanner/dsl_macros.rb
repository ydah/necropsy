# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def handle_module_relation(node, context)
      return unless MODULE_RELATION_MACROS.include?(node.name)
      return unless context.owner

      unless static_module_relation?(node, context)
        constants = arguments(node).filter_map { |argument| constant_name(argument) }
        class_record(context.owner)[:dynamic] = true
        record_semantic_blocker(
          :dynamic_ancestry,
          node,
          context,
          "#{node.name} is not an unconditional load-time ancestry mutation",
          suggested_action: :make_ancestry_static,
          scope_owner: [context.owner, *constants].uniq,
          force_global: %w[BasicObject Kernel Object].include?(context.owner)
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
        candidates = constant_candidates(constant, context.lexical_nesting)
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
      return false unless context.owner
      return false if context.test

      if runtime_block_macro_enabled?(node)
        callback = keyword_value(node, 'callback')
        if callback.is_a?(String)
          entrypoint_hints << EntryPoint.new(
            node_id: "#{context.owner}##{callback}", reason: :callback_registered,
            evidence: { 'type' => 'runtime_callback', 'macro' => node.name.to_s }
          )
        elsif keyword_keys(node).include?('callback')
          record_semantic_blocker(
            :framework_runtime_callback,
            node,
            context,
            "#{node.name} callback is not statically bounded",
            suggested_action: :review_callback
          )
        end
        if node.block
          synthetic = visit_synthetic_body(node.block.body, context, :runtime_callback_block)
          entrypoint_hints << EntryPoint.new(
            node_id: synthetic.graph_id,
            reason: :callback_registered,
            evidence: { 'type' => 'runtime_callback_block', 'macro' => node.name.to_s }
          )
          return true
        end
        return false
      end

      if RAILS_CALLBACK_MACROS.include?(node.name)
        return false if callback_disabled?(node)

        record_callback_condition_blocker(node, context) if callback_condition_unknown?(node)
        callback_names(node).each do |method_name|
          entrypoint_hints << EntryPoint.new(node_id: "#{context.owner}##{method_name}", reason: :callback_registered)
        end
        callback_condition_names(node).each do |method_name|
          entrypoint_hints << EntryPoint.new(
            node_id: "#{context.owner}##{method_name}",
            reason: :callback_registered,
            evidence: { 'type' => 'callback_condition', 'macro' => node.name.to_s }
          )
        end
        if node.block
          synthetic = visit_synthetic_body(node.block.body, context, :callback_block)
          entrypoint_hints << EntryPoint.new(
            node_id: synthetic.graph_id,
            reason: :callback_registered,
            evidence: { 'type' => 'callback_block', 'macro' => node.name.to_s }
          )
          return true
        end
      elsif node.name == :validates
        custom_validator_names(node).each do |validator|
          constant_candidates("#{validator}Validator", context.lexical_nesting).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate_each", reason: :callback_registered)
          end
        end
      elsif node.name == :validates_with
        arguments(node).filter_map { |argument| constant_name(argument) }.each do |validator|
          constant_candidates(validator, context.lexical_nesting).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate", reason: :callback_registered)
          end
        end
      end
      false
    end

    def runtime_block_macro_enabled?(node)
      return framework_enabled?('rails') if RAILS_RUNTIME_BLOCK_MACROS.include?(node.name)
      return framework_enabled?('sidekiq') if SIDEKIQ_RUNTIME_BLOCK_MACROS.include?(node.name)

      false
    end

    def handle_graphql_field(node, context)
      return unless node.name == :field && context.owner && !context.test
      return unless framework_enabled?('graphql')
      return unless graphql_owner?(context.owner)

      method_name = if keyword_keys(node).include?('method')
                      keyword_value(node, 'method')
                    else
                      literal_argument(node, index: 0)
                    end
      if method_name.is_a?(String)
        entrypoint_hints << EntryPoint.new(
          node_id: "#{context.owner}##{method_name}",
          reason: :graphql_field,
          evidence: { 'type' => 'graphql_field', 'field' => literal_argument(node, index: 0) }
        )
      else
        record_semantic_blocker(
          :graphql_field,
          node,
          context,
          'GraphQL field resolver method is not statically bounded',
          suggested_action: :review_graphql_field
        )
      end
    end

    def graphql_owner?(owner)
      owner.end_with?('Type', 'Resolver', 'Mutation', 'Subscription') ||
        convention_ancestors(owner).any? { |ancestor| ancestor.start_with?('GraphQL::') }
    end

    def framework_enabled?(name)
      project.config.frameworks(reference_files: project.reference_files).include?(name)
    rescue SystemCallError, EncodingError
      project.config.frameworks.include?(name)
    end

    def callback_condition_names(node)
      %w[if unless].filter_map do |key|
        value = keyword_value(node, key)
        value if value.is_a?(String)
      end.uniq
    end

    def callback_disabled?(node)
      (keyword_keys(node).include?('if') && keyword_value(node, 'if') == false) ||
        (keyword_keys(node).include?('unless') && keyword_value(node, 'unless') == true)
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
      return false unless RAILS_GENERATED_METHOD_MACROS.include?(node.name)
      return false unless context.owner && !context.test && rails_framework_enabled?

      return handle_rails_enum(node, context) if node.name == :enum
      return handle_rails_scope(node, context) if node.name == :scope

      names = literal_positional_names(node)
      if names.empty?
        record_semantic_blocker(
          :rails_generated_methods,
          node,
          context,
          "#{node.name} has dynamic generated method names",
          suggested_action: :review_generated_methods
        )
        return handled_call
      end

      case node.name
      when :store_accessor
        add_generated_methods(context, names.drop(1).flat_map { |name| [name, "#{name}="] }, node)
      when :store
        accessors = array_keyword_values(node, 'accessors')
        add_generated_methods(context, [names.first, "#{names.first}=", *accessors.flat_map { |name| [name, "#{name}="] }], node)
      when :attribute
        add_generated_methods(context, [names.first, "#{names.first}="], node)
      when :class_attribute, :mattr_reader, :mattr_writer, :mattr_accessor,
           :cattr_reader, :cattr_writer, :cattr_accessor
        reader = !node.name.to_s.end_with?('_writer')
        writer = !node.name.to_s.end_with?('_reader')
        generated = names.flat_map { |name| [reader && name, writer && "#{name}="].compact }
        add_generated_methods(context, generated, node)
        add_generated_methods(context, generated, node, kind: :singleton_method)
      when :belongs_to, :has_one
        names.each do |name|
          add_generated_methods(
            context,
            [name, "#{name}=", "build_#{name}", "create_#{name}", "create_#{name}!", "reload_#{name}", "reset_#{name}"],
            node
          )
        end
      when :has_many
        names.each { |name| add_generated_methods(context, [name, "#{name}="], node) }
      end
      handled_call
    end

    def handle_rails_enum(node, context)
      declarations = enum_declarations(node)
      if declarations.empty?
        record_semantic_blocker(
          :rails_generated_methods,
          node,
          context,
          'enum has a dynamic name or value set',
          suggested_action: :review_generated_methods
        )
        return handled_call
      end

      declarations.each do |enum_name, values|
        add_generated_methods(context, [enum_name, "#{enum_name}="], node)
        next if keyword_value(node, 'instance_methods') == false

        decorated = values.map { |value| decorate_enum_value(enum_name, value, node) }
        add_generated_methods(context, decorated.flat_map { |value| ["#{value}?", "#{value}!"] }, node)
        next if keyword_value(node, 'scopes') == false

        scopes = decorated.flat_map { |value| [value, "not_#{value}"] }
        add_generated_methods(context, scopes, node, kind: :singleton_method)
      end
      handled_call
    end

    def enum_declarations(node)
      positional = arguments(node).grep_v(Prism::KeywordHashNode)
      if literal_name?(positional.first)
        values = literal_hash_keys(positional[1])
        values = literal_array_values(positional[1]) if values.empty?
        if values.empty?
          options = %w[prefix suffix _prefix _suffix scopes instance_methods validate]
          values = keyword_keys(node) - options
        end
        return [[literal_value(positional.first), values]] unless values.empty?
      end

      keyword_hash = arguments(node).find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      Array(keyword_hash&.elements).filter_map do |element|
        next unless element.is_a?(Prism::AssocNode)

        enum_name = literal_value(element.key)
        values = literal_hash_keys(element.value)
        values = literal_array_values(element.value) if values.empty?
        [enum_name, values] if enum_name && !values.empty?
      end
    end

    def decorate_enum_value(enum_name, value, node)
      prefix = keyword_value(node, 'prefix') || keyword_value(node, '_prefix')
      suffix = keyword_value(node, 'suffix') || keyword_value(node, '_suffix')
      value = "#{prefix == true ? enum_name : prefix}_#{value}" if prefix
      value = "#{value}_#{suffix == true ? enum_name : suffix}" if suffix
      value
    end

    def handle_rails_scope(node, context)
      name = literal_argument(node, index: 0)
      unless name
        record_semantic_blocker(
          :rails_generated_methods,
          node,
          context,
          'scope has a runtime-computed name',
          suggested_action: :review_generated_methods
        )
        return handled_call
      end

      definition = add_generated_methods(context, [name], node, kind: :singleton_method).first
      callable = arguments(node)[1]
      body = callable.body if callable.is_a?(Prism::LambdaNode)
      body ||= node.block&.body
      if body
        scope_context = context.dup
        scope_context.current_caller_id = definition.graph_id
        scope_context.current_method_name = name
        scope_context.current_kind = :singleton_method
        scope_context.static_ancestry = false
        scope_context.flow_result = nil
        visit(body, scope_context)
        return handled_call(arguments: false)
      end

      record_semantic_blocker(
        :rails_generated_methods,
        node,
        context,
        'scope body is not a literal block or lambda',
        suggested_action: :review_generated_methods
      )
      handled_call
    end

    def literal_positional_names(node)
      arguments(node).grep_v(Prism::KeywordHashNode).filter_map do |argument|
        literal_value(argument) if literal_name?(argument)
      end
    end

    def array_keyword_values(node, key)
      hash = arguments(node).find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      pair = Array(hash&.elements).find do |element|
        element.is_a?(Prism::AssocNode) && literal_value(element.key).to_s == key
      end
      literal_array_values(pair&.value)
    end

    def literal_hash_keys(node)
      return [] unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

      Array(node.elements).filter_map do |element|
        literal_value(element.key) if element.is_a?(Prism::AssocNode) && literal_name?(element.key)
      end
    end

    def literal_array_values(node)
      return [] unless node.is_a?(Prism::ArrayNode) && !node.contains_splat?

      node.elements.filter_map { |element| literal_value(element) if literal_name?(element) }
    end

    def rails_framework_enabled?
      project.config.frameworks.include?('rails') || project.config.rails_enabled?(reference_files: project.reference_files)
    rescue SystemCallError, EncodingError
      project.config.frameworks.include?('rails')
    end

    def add_generated_methods(context, names, source_node, kind: nil)
      names.uniq.map do |name|
        generated_kind, separator = if kind
                                      [kind, kind == :singleton_method ? '.' : '#']
                                    else
                                      method_kind_and_separator(context)
                                    end
        add_definition(
          symbol_id: "#{context.owner}#{separator}#{name}",
          kind: generated_kind,
          source_node: source_node,
          context: context,
          defined_via: :"rails_#{source_node.name}",
          owner: context.owner,
          name: name,
          visibility: :public
        )
      end
    end

    def handle_attr_macro(node, context)
      return false unless ATTR_MACROS.include?(node.name)
      return false unless context.owner

      names = arguments(node).filter_map { |argument| literal_value(argument) if literal_name?(argument) }
      if names.length != arguments(node).length
        record_semantic_blocker(
          :dynamic_generated_methods,
          node,
          context,
          "#{node.name} has a runtime-computed method name",
          suggested_action: :make_method_name_literal
        )
      end

      names.each do |name|
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
      handled_call
    end

    def handle_delegate(node, context)
      return false unless node.name == :delegate
      return false unless context.owner

      target = keyword_value(node, 'to')
      prefix = keyword_value(node, 'prefix')
      positional = arguments(node).grep_v(Prism::KeywordHashNode)
      names = positional.filter_map { |argument| literal_value(argument) if literal_name?(argument) }
      if names.length != positional.length || target.nil?
        record_semantic_blocker(
          :dynamic_generated_methods,
          node,
          context,
          'delegate name or target is not statically bounded',
          suggested_action: :make_delegate_literal
        )
      end

      names.each do |name|
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
      handled_call
    end

    def handle_forwardable(node, context)
      return false unless %i[def_delegator def_delegators].include?(node.name)
      return false unless context.owner

      symbols = symbol_arguments(node)
      if symbols.length < 2 || symbols.length != arguments(node).length
        record_semantic_blocker(
          :dynamic_generated_methods,
          node,
          context,
          "#{node.name} has runtime-computed delegation names",
          suggested_action: :make_delegate_literal
        )
        return handled_call
      end

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
      handled_call
    end
  end
end
