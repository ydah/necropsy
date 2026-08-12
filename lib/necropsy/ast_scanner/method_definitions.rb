# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def handle_define_method(node, context)
      return false unless node.name == :define_method
      return false unless context.owner

      method_name = literal_argument(node, index: 0)
      unless method_name
        record_semantic_blocker(
          :dynamic_definition,
          node,
          context,
          'define_method name is not statically bounded',
          suggested_action: :make_method_name_literal
        )
        visit_synthetic_body(node.block&.body, context, :dynamic_define_method)
        return true
      end

      kind, separator = method_kind_and_separator(context)
      id = "#{context.owner}#{separator}#{method_name}"
      definition = add_definition(
        symbol_id: id,
        kind: kind,
        source_node: node,
        context: context,
        defined_via: :define_method,
        owner: context.owner,
        name: method_name,
        visibility: context.visibility
      )
      record_module_function_copy(node, context, definition) if context.module_function

      if node.block
        block_context = context.dup
        block_context.current_caller_id = definition.graph_id
        block_context.current_method_name = method_name
        block_context.current_kind = kind
        block_context.singleton_scope = false
        block_context.visibility = :public
        block_context.module_function = false
        block_context.static_ancestry = false
        visit(node.block.body, block_context)
      end
      true
    end

    def handle_define_singleton_method(node, context)
      return false unless node.name == :define_singleton_method

      owner = definition_owner_for_call(node, context)
      method_name = literal_argument(node, index: 0)
      unless owner && method_name
        record_semantic_blocker(
          :dynamic_singleton_definition,
          node,
          context,
          'define_singleton_method receiver or name is not statically bounded',
          suggested_action: :make_singleton_definition_static,
          scope_owner: owner,
          force_global: !owner
        )
        visit_synthetic_body(node.block&.body, context, :dynamic_define_singleton_method)
        return true
      end

      id = "#{owner}.#{method_name}"
      definition = add_definition(
        symbol_id: id,
        kind: :singleton_method,
        source_node: node,
        context: context,
        defined_via: :define_singleton_method,
        owner: owner,
        name: method_name,
        visibility: :public
      )
      if node.block
        block_context = context.dup
        block_context.owner = owner
        block_context.current_caller_id = definition.graph_id
        block_context.current_method_name = method_name
        block_context.current_kind = :singleton_method
        block_context.singleton_scope = false
        block_context.visibility = :public
        block_context.module_function = false
        block_context.static_ancestry = false
        visit(node.block.body, block_context)
      end
      true
    end

    def handle_eval(node, context)
      return false unless %i[class_eval class_exec module_eval module_exec instance_eval instance_exec eval].include?(node.name)

      owner = eval_owner(node, context)
      unless node.block && owner && node.name != :eval
        record_semantic_blocker(
          :variable_eval,
          node,
          context,
          'Eval receiver or source is not statically bounded',
          suggested_action: :replace_variable_eval,
          scope_owner: node.name == :eval ? nil : owner,
          receiver_kind: %i[instance_eval instance_exec].include?(node.name) ? :constant : nil,
          force_global: node.name == :eval
        )
        visit_synthetic_body(node.block&.body, context, :dynamic_eval)
        return true
      end

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = %i[instance_eval instance_exec].include?(node.name)
      block_context.visibility = :public
      block_context.module_function = false
      block_context.static_ancestry = false
      visit(node.block.body, block_context)
      true
    end

    def handle_unsupported_semantics(node, context)
      return false unless %i[refine using].include?(node.name)

      record_semantic_blocker(
        :unsupported_refinement,
        node,
        context,
        "#{node.name} changes lexical method lookup and is not resolved",
        suggested_action: :review_refinement_scope
      )
      true
    end

    def record_semantic_blocker(kind, node, context, reason, suggested_action: :review,
                                scope_owner: context.owner, receiver_kind: nil, force_global: false)
      global = force_global || !scope_owner
      scope_kind = global ? :global : :owner
      scope_value = global ? '*' : scope_owner
      metadata = {
        'caller_domain' => context.test ? 'test' : 'runtime',
        'caller_id' => context.current_caller_id,
        'semantic_operation' => (node.respond_to?(:name) ? node.name : node.type).to_s,
        'owner_scope' => Array(scope_owner).compact,
        'file' => context.relative_file,
        'line' => node.location.start_line,
        'reason_code' => kind.to_s
      }
      metadata['receiver_kind'] = receiver_kind.to_s if receiver_kind
      semantic_blockers << Blocker.new(
        kind: kind,
        scope_kind: scope_kind,
        scope_value: scope_value,
        source: 'ast_scanner',
        reason: reason,
        suggested_action: suggested_action,
        metadata: metadata
      )
    end

    def handle_visibility(node, context)
      return false unless VISIBILITY_MACROS.include?(node.name)
      return false unless context.owner

      modifier_definitions = arguments(node).grep(Prism::DefNode)
      class_method = node.name.to_s.end_with?('_class_method')
      visibility = node.name.to_s.delete_suffix('_class_method').to_sym
      unless modifier_definitions.empty?
        modifier_definitions.each do |definition|
          definition_context = context.dup
          definition_context.visibility = visibility
          visit_def(definition, definition_context)
        end
        return true
      end

      modifier_calls = arguments(node).grep(Prism::CallNode)
      unless modifier_calls.empty?
        modifier_calls.each { |call| visit(call, context) }
        names = [*symbol_arguments(node), *modifier_calls.flat_map { |call| visibility_result_names(call) }].uniq
        names.each { |name| update_method_visibility(context, name, visibility, node, singleton: class_method) }
        record_unknown_visibility_result(node, context, modifier_calls, visibility) if names.empty?
        arguments(node).reject { |argument| argument.is_a?(Prism::CallNode) || argument.is_a?(Prism::DefNode) }
                       .each { |argument| visit(argument, context) }
        return :children_visited
      end

      names = symbol_arguments(node)
      if names.empty?
        unless class_method
          context.visibility = visibility
          context.module_function = false
        end
      else
        names.each { |name| update_method_visibility(context, name, visibility, node, singleton: class_method) }
      end
      true
    end

    def visibility_result_names(call)
      names = symbol_arguments(call)
      case call.name
      when :attr_reader
        names
      when :attr_writer
        names.map { |name| "#{name}=" }
      when :attr_accessor
        names.flat_map { |name| [name, "#{name}="] }
      else
        []
      end
    end

    def record_unknown_visibility_result(node, context, modifier_calls, visibility)
      operations = modifier_calls.map(&:name).compact.map(&:to_s).uniq.sort
      record_semantic_blocker(
        :visibility_activation,
        node,
        context,
        "#{visibility} receives runtime-computed method names from #{operations.join(', ')}",
        suggested_action: :review_load_order
      )
    end

    def handle_module_function(node, context)
      return false unless node.name == :module_function
      return false unless context.owner

      modifier_definitions = arguments(node).grep(Prism::DefNode)
      unless modifier_definitions.empty?
        modifier_definitions.each do |definition|
          definition_context = context.dup
          definition_context.module_function = true
          definition_context.visibility = :private
          visit_def(definition, definition_context)
        end
        return true
      end

      names = symbol_arguments(node)
      if names.empty?
        context.module_function = true
        context.visibility = :private
      else
        names.each { |name| defer_module_function(context, name, node) }
      end
      true
    end

    def record_module_function_copy(node, context, instance_node)
      copy = add_module_function_definition(context, instance_node.name, node)
      module_function_sources[copy.graph_id] = [instance_node.graph_id]
      method_signatures[copy.graph_id] = method_signatures[instance_node.graph_id] if method_signatures[instance_node.graph_id]
    end

    def handle_alias_method(node, context)
      return false unless node.name == :alias_method
      return false unless context.owner

      new_name, old_name = symbol_arguments(node)
      return false unless new_name && old_name

      record_alias_method(context, node, new_name, old_name)
      true
    end

    def handle_method_removal(node, context)
      return false unless %i[remove_method undef_method].include?(node.name)
      return false unless context.owner

      names = symbol_arguments(node)
      if names.empty?
        record_semantic_blocker(
          :dynamic_method_removal,
          node,
          context,
          "#{node.name} target is not statically bounded",
          suggested_action: :make_method_name_literal,
          force_global: true
        )
        return true
      end

      names.each do |name|
        semantic_blockers << Blocker.new(
          kind: node.name,
          scope_kind: :message,
          scope_value: name,
          source: 'ast_scanner',
          reason: "#{context.owner} #{node.name}s #{name}; activation order is not closed",
          suggested_action: :review_method_activation,
          metadata: {
            'caller_domain' => context.test ? 'test' : 'runtime',
            'caller_id' => context.current_caller_id,
            'owner_scope' => [context.owner],
            'file' => context.relative_file,
            'line' => node.location.start_line,
            'message' => name,
            'reason_code' => node.name.to_s
          }
        )
      end
      true
    end

    def visit_alias_method_node(node, context)
      return visit_children(node, context) unless context.owner

      new_name = node.new_name.unescaped.to_s
      old_name = node.old_name.unescaped.to_s
      record_alias_method(context, node, new_name, old_name)
    end

    def record_alias_method(context, source_node, new_name, old_name)
      kind = context.singleton_scope ? :singleton_method : :instance_method
      separator = kind == :singleton_method ? '.' : '#'
      id = "#{context.owner}#{separator}#{new_name}"
      physical_source = physical_alias_source(context, source_node, old_name, kind)
      definition = add_definition(
        symbol_id: id,
        kind: kind,
        source_node: source_node,
        context: context,
        defined_via: :alias_method,
        owner: context.owner,
        name: new_name,
        visibility: physical_source&.visibility || context.visibility
      )
      metadata = { 'original_message' => old_name, 'alias_method' => true }
      metadata['physical_target_definition_id'] = physical_source.graph_id if physical_source
      add_scanned_call_site(
        source_node: source_node,
        context: context,
        role: :alias_target,
        caller_id: definition.graph_id,
        message: old_name,
        receiver_kind: :self,
        receiver_name: context.owner,
        dynamic: false,
        metadata: metadata
      )
    end

    def physical_alias_source(context, source_node, old_name, kind)
      return unless context.static_ancestry

      nodes.select do |definition|
        definition.kind == kind && definition.owner == context.owner && definition.name == old_name &&
          definition.file == context.relative_file && definition.line <= source_node.location.start_line
      end.max_by { |definition| [definition.line, definition.ordinal] }
    end
  end
end
