# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def handle_define_method(node, context)
      return false unless node.name == :define_method
      return false unless context.owner

      method_name = first_symbol_argument(node)
      return false unless method_name

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
      method_name = first_symbol_argument(node) || first_string_argument(node)
      return false unless owner && method_name

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
      return false unless %i[class_eval module_eval instance_eval eval].include?(node.name)

      owner = eval_owner(node, context)
      unless %i[class_eval module_eval].include?(node.name) && node.block && owner
        record_semantic_blocker(
          :variable_eval,
          node,
          context,
          'Eval receiver or source is not statically bounded',
          suggested_action: :replace_variable_eval,
          scope_owner: node.name == :eval ? nil : owner,
          receiver_kind: node.name == :instance_eval ? :constant : nil,
          force_global: node.name == :eval
        )
        return true
      end

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = false
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
      global = force_global || kind == :dynamic_ancestry || !scope_owner
      scope_kind = global ? :global : :owner
      scope_value = global ? '*' : scope_owner
      metadata = {
        'caller_domain' => context.test ? 'test' : 'runtime',
        'caller_id' => context.current_caller_id,
        'semantic_operation' => node.name.to_s,
        'owner_scope' => [scope_owner].compact,
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

      names = symbol_arguments(node)
      class_method = node.name.to_s.end_with?('_class_method')
      visibility = node.name.to_s.delete_suffix('_class_method').to_sym
      if names.empty?
        unless class_method
          context.visibility = visibility
          context.module_function = false
        end
      else
        names.each { |name| update_method_visibility(context, name, visibility, singleton: class_method) }
      end
      true
    end

    def handle_module_function(node, context)
      return false unless node.name == :module_function
      return false unless context.owner

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
      definition = add_definition(
        symbol_id: id,
        kind: kind,
        source_node: source_node,
        context: context,
        defined_via: :alias_method,
        owner: context.owner,
        name: new_name,
        visibility: context.visibility
      )
      add_scanned_call_site(
        source_node: source_node,
        context: context,
        role: :alias_target,
        caller_id: definition.graph_id,
        message: old_name,
        receiver_kind: :self,
        receiver_name: context.owner,
        dynamic: false,
        metadata: { 'original_message' => old_name, 'alias_method' => true }
      )
    end
  end
end
