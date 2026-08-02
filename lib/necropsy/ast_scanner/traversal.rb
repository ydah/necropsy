# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def copy_module_function_call_sites
      module_functions = nodes.select { |node| node.defined_via == :module_function }
      copies = module_functions.flat_map do |node|
        instance_id = "#{node.owner}##{node.name}"
        call_sites.select { |site| site.caller_id == instance_id }.map do |site|
          site.with(caller_id: node.id, metadata: site.metadata.merge('module_function' => true))
        end
      end
      call_sites.concat(copies)
    end

    def scan_file(file)
      relative = project.relative_path(file)
      root_id = "file:#{relative}"
      test = project.test_file?(file)
      nodes << Node.new(
        id: root_id,
        kind: :block_entry,
        file: relative,
        line: 1,
        end_line: 1,
        defined_via: :file,
        owner: nil,
        name: relative,
        test: test,
        visibility: :public
      )

      result = Prism.parse(File.read(file))
      record_parse_errors(root_id, result) if result.failure?

      visit(
        result.value,
        Context.new(
          namespace: nil,
          owner: nil,
          current_caller_id: root_id,
          current_kind: :block_entry,
          root_id: root_id,
          file: file,
          relative_file: relative,
          test: test,
          singleton_scope: false,
          visibility: :public,
          module_function: false
        )
      )
    rescue SystemCallError, EncodingError => e
      uncertainties[root_id] << "Could not parse #{relative}: #{e.message}"
    end

    def visit(node, context)
      return unless node.respond_to?(:child_nodes)

      case node
      when Prism::ClassNode, Prism::ModuleNode
        visit_namespace(node, context)
      when Prism::DefNode
        visit_def(node, context)
      when Prism::CallNode
        visit_call(node, context)
      when Prism::AliasMethodNode
        visit_alias_method_node(node, context)
      when Prism::SuperNode, Prism::ForwardingSuperNode
        visit_super(node, context)
      when Prism::SingletonClassNode
        visit_singleton_class(node, context)
      when Prism::ConstantWriteNode
        visit_constant_write(node, context)
      else
        node.child_nodes.compact.each { |child| visit(child, context) }
      end
    end

    def visit_namespace(node, context)
      namespace = qualify_constant(constant_name(node.constant_path), context.namespace)
      record_class_info(node, namespace, context)
      child_context = context.dup
      child_context.namespace = namespace
      child_context.owner = namespace
      child_context.singleton_scope = false
      child_context.visibility = :public
      child_context.module_function = false
      visit(node.body, child_context)
    end

    def visit_def(node, context)
      owner = definition_owner(node, context)
      return visit_children(node, context) unless owner

      kind = node.receiver || context.singleton_scope ? :singleton_method : :instance_method
      separator = kind == :singleton_method ? '.' : '#'
      id = "#{owner}#{separator}#{node.name}"
      nodes << Node.new(
        id: id,
        kind: kind,
        file: context.relative_file,
        line: node.location.start_line,
        end_line: node.location.end_line,
        defined_via: :def,
        owner: owner,
        name: node.name.to_s,
        test: context.test,
        visibility: node.receiver ? :public : context.visibility
      )
      record_module_function_copy(node, context, owner) if kind == :instance_method && context.module_function
      if node.name == :method_missing
        uncertainties[id] << "#{owner} defines method_missing"
        class_record(owner)[:dynamic] = true
      end

      method_context = context.dup
      method_context.owner = owner
      method_context.current_caller_id = id
      method_context.current_kind = kind
      method_context.singleton_scope = false
      method_context.visibility = :public
      method_context.module_function = false
      visit(node.body, method_context)
    end

    def visit_call(node, context)
      return if handle_visibility(node, context)
      return if handle_module_function(node, context)
      return if handle_eval(node, context)
      return if handle_define_singleton_method(node, context)
      return if handle_define_method(node, context)
      return if handle_attr_macro(node, context)
      return if handle_delegate(node, context)
      return if handle_forwardable(node, context)
      return if handle_alias_method(node, context)

      handle_module_relation(node, context)
      handle_rails_callback(node, context)

      record_instantiation(node, context)
      record_symbol_reference(node, context)
      record_symbol_to_proc(node, context)
      site = build_call_site(node, context)
      call_sites << site if site
      if site&.dynamic
        record_uncertainty(site)
      elsif unresolved_dynamic_dispatch?(node)
        record_uncertainty_at(node, context)
      end

      visit_children(node, context)
    end

    def visit_super(node, context)
      method_name = context.current_caller_id&.split(/[.#]/)&.last
      if method_name
        call_sites << CallSite.new(
          caller_id: context.current_caller_id,
          message: method_name,
          receiver_kind: :super,
          receiver_name: context.owner,
          file: context.relative_file,
          line: node.location.start_line,
          test: context.test,
          dynamic: false,
          metadata: { 'super' => true }
        )
      end
      visit_children(node, context)
    end

    def visit_singleton_class(node, context)
      return visit_children(node, context) unless node.expression.is_a?(Prism::SelfNode) && context.owner

      singleton_context = context.dup
      singleton_context.singleton_scope = true
      singleton_context.visibility = :public
      singleton_context.module_function = false
      visit(node.body, singleton_context)
    end
  end
end
