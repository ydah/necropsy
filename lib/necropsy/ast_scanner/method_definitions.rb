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
      record_module_function_copy(node, context, context.owner, method_name) if context.module_function

      if node.block
        block_context = context.dup
        block_context.current_caller_id = definition.graph_id
        block_context.current_method_name = method_name
        block_context.current_kind = kind
        block_context.singleton_scope = false
        block_context.visibility = :public
        block_context.module_function = false
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
        visit(node.block.body, block_context)
      end
      true
    end

    def handle_eval(node, context)
      return false unless %i[class_eval module_eval].include?(node.name)
      return false unless node.block

      owner = eval_owner(node, context)
      return false unless owner

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = false
      block_context.visibility = :public
      block_context.module_function = false
      visit(node.block.body, block_context)
      true
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
        names.each { |name| promote_module_function(context, name, node) }
      end
      true
    end

    def record_module_function_copy(node, context, _owner, method_name = node.name.to_s)
      promote_module_function(context, method_name, node)
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
      call_sites << CallSite.new(
        caller_id: definition.graph_id,
        message: old_name,
        receiver_kind: :self,
        receiver_name: context.owner,
        file: context.relative_file,
        line: source_node.location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'original_message' => old_name, 'alias_method' => true }
      )
    end
  end
end
