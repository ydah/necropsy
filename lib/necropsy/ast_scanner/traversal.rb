# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def resolve_deferred_module_function_sources
      deferred_module_functions.each do |copy_id, instance_id|
        module_function_sources[copy_id] = nodes.filter_map do |definition|
          definition.graph_id if definition.kind == :instance_method && definition.symbol_id == instance_id
        end
        signatures = module_function_sources.fetch(copy_id).filter_map { |source_id| method_signatures[source_id] }.uniq
        method_signatures[copy_id] = signatures.first if signatures.one?
      end
    end

    def copy_module_function_call_sites
      copies = module_function_sources.flat_map do |copy_id, source_ids|
        source_ids.flat_map do |source_id|
          call_sites.select { |site| site.caller_id == source_id }.map do |site|
            derived_call_site(
              site, derivation: :module_function, caller_id: copy_id,
                    metadata: { 'module_function' => true }
            )
          end
        end
      end
      call_sites.concat(copies)
    end

    def scan_file(file)
      relative = project.relative_path(file)
      test = project.test_file?(file)
      context = Context.new(
        namespace: nil,
        owner: nil,
        current_caller_id: nil,
        current_method_name: nil,
        current_kind: :block_entry,
        root_id: nil,
        file: file,
        relative_file: relative,
        test: test,
        singleton_scope: false,
        visibility: :public,
        module_function: false,
        static_ancestry: true,
        flow_result: nil
      )
      result = Prism.parse(File.read(file))
      root = add_definition(
        symbol_id: "file:#{relative}",
        kind: :block_entry,
        source_node: result.value,
        context: context,
        defined_via: :file,
        owner: nil,
        name: relative,
        visibility: :public
      )
      root_id = root.graph_id
      context.current_caller_id = root_id
      context.root_id = root_id

      if result.failure?
        file_statuses[relative] = :recovered
        record_parse_errors(root_id, relative, result)
      else
        file_statuses[relative] = :complete
      end

      visit(result.value, context)
    rescue DefinitionIdentity::CanonicalizationError, SystemStackError, SystemCallError, EncodingError => e
      record_source_failure(root_id || "file:#{relative}", relative, e)
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
        visit_generic_node(node, context)
      end
    end

    def visit_generic_node(node, context)
      return visit_children(node, context) unless ANCESTRY_CONTROL_FLOW_TYPES.include?(node.type)

      nested_context = context.dup
      nested_context.static_ancestry = false
      visit_children(node, nested_context)
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
      definition = add_definition(
        symbol_id: id,
        kind: kind,
        source_node: node,
        context: context,
        defined_via: :def,
        owner: owner,
        name: node.name.to_s,
        visibility: node.receiver ? :public : context.visibility
      )
      method_signatures[definition.graph_id] = method_signature(node.parameters)
      record_module_function_copy(node, context, definition) if kind == :instance_method && context.module_function
      if %i[method_missing respond_to_missing?].include?(node.name)
        uncertainties[definition.graph_id] << "#{owner} defines #{node.name}"
        class_record(owner)[:dynamic] = true
      end
      if node.name.to_s.start_with?('on_')
        rule_hit = convention_rules.method_hit(
          owner: owner,
          method_name: node.name,
          ancestors: convention_ancestors(owner),
          frameworks: project.config.frameworks
        )
        if rule_hit
          entrypoint_hints << EntryPoint.new(
            node_id: definition.graph_id,
            reason: :convention_callback,
            evidence: { 'type' => 'convention_rule', **rule_hit }
          )
        end
      end

      method_context = context.dup
      method_context.owner = owner
      method_context.current_caller_id = definition.graph_id
      method_context.current_method_name = node.name.to_s
      method_context.current_kind = kind
      method_context.singleton_scope = false
      method_context.visibility = :public
      method_context.module_function = false
      method_context.static_ancestry = false
      method_context.flow_result = FlowInterpreter.new(
        constant_resolver: lambda do |constant|
          resolve_candidate_group(constant_candidates(constant, method_context.namespace))
        end
      ).analyze(node.body)
      method_context.flow_result.issues.each do |issue|
        record_semantic_blocker(
          :flow_budget,
          node,
          method_context,
          "forward value analysis stopped at #{issue}",
          suggested_action: :review_value_flow
        )
      end
      visit(node.body, method_context)
    end

    def convention_ancestors(owner)
      ancestors = []
      current_data = class_data[owner]
      current = current_data&.fetch(:superclass_candidates, [])&.first
      while current && !ancestors.include?(current)
        ancestors << current
        current_data = class_data[current]
        current = current_data&.fetch(:superclass_candidates, [])&.first
      end
      ancestors
    end

    def visit_call(node, context)
      return if handle_unsupported_semantics(node, context)
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
      sites = build_call_sites(node, context).compact
      call_sites.concat(sites)
      sites.each { |site| record_uncertainty(site) if site.dynamic }
      record_uncertainty_at(node, context) if sites.empty? && unresolved_dynamic_dispatch?(node)

      visit_children(node, context)
    end

    def visit_super(node, context)
      method_name = context.current_method_name
      if method_name
        add_scanned_call_site(
          source_node: node,
          context: context,
          role: :super,
          message: method_name,
          receiver_kind: :super,
          receiver_name: context.owner,
          dynamic: false,
          metadata: {
            'super' => true,
            'zsuper' => node.is_a?(Prism::ForwardingSuperNode),
            'arguments' => node.is_a?(Prism::ForwardingSuperNode) ? incomplete_arguments : call_arguments(node)
          }
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
