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
        lexical_nesting: [],
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
      visit(node.superclass, context) if node.respond_to?(:superclass) && node.superclass
      child_context = context.dup
      child_context.namespace = namespace
      child_context.lexical_nesting = [namespace, *context.lexical_nesting].compact.uniq
      child_context.owner = namespace
      child_context.singleton_scope = false
      child_context.visibility = :public
      child_context.module_function = false
      visit(node.body, child_context)
    end

    def visit_def(node, context)
      owner = definition_owner(node, context)
      unless owner
        visit(node.receiver, context) if node.receiver
        record_semantic_blocker(
          :dynamic_singleton_definition,
          node,
          context,
          'singleton method receiver is not statically bounded',
          suggested_action: :make_singleton_receiver_static,
          force_global: true
        )
        visit_synthetic_body(node.body, context, :dynamic_singleton_method)
        return
      end

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
          resolve_candidate_group(constant_candidates(constant, method_context.lexical_nesting))
        end
      ).analyze(node.body)
      method_context.flow_result.issues.each do |issue|
        uncertainties[definition.graph_id] << "Forward value analysis stopped at #{issue}; affected calls use conservative lookup"
      end
      visit_default_parameters(node.parameters, method_context)
      visit(node.body, method_context)
    end

    def visit_default_parameters(parameters, context)
      return unless parameters

      defaults = [*Array(parameters.optionals), *Array(parameters.keywords)].filter_map do |parameter|
        parameter.value if parameter.respond_to?(:value)
      end
      defaults.each { |default| visit(default, context) }
    end

    def convention_ancestors(owner)
      ancestors = []
      pending = convention_parent_candidates(class_data[owner])
      until pending.empty?
        current = pending.shift
        next if ancestors.include?(current)

        ancestors << current
        pending.concat(convention_parent_candidates(class_data[current]))
      end
      ancestors
    end

    def convention_parent_candidates(data)
      return [] unless data

      Array(data[:superclass_candidates]) +
        %i[includes prepends extends singleton_includes singleton_prepends].flat_map do |relation|
          Array(data[relation]).flatten
        end
    end

    def visit_call(node, context)
      handlers = %i[
        handle_unsupported_semantics handle_visibility handle_module_function handle_eval
        handle_define_singleton_method handle_define_method handle_attr_macro handle_delegate
        handle_forwardable handle_alias_method handle_method_removal
      ]
      handled = handlers.lazy.map { |handler| send(handler, node, context) }.find(&:itself)
      if handled
        raise TypeError, "semantic call handler must return AstScanner::CallTraversal, got #{handled.class}" unless
          handled.is_a?(CallTraversal)

        visit_call_children(
          node,
          context,
          visit_receiver: handled.receiver,
          visit_arguments: handled.arguments,
          visit_block: handled.block
        )
        return
      end

      handle_module_relation(node, context)
      callback_block_consumed = handle_rails_callback(node, context)
      handle_graphql_field(node, context)
      if handle_generated_rails_methods(node, context)
        visit_call_children(node, context, visit_block: false)
        return
      end

      record_instantiation(node, context)
      record_symbol_reference(node, context)
      record_symbol_to_proc(node, context)
      sites = build_call_sites(node, context).compact
      call_sites.concat(sites)
      sites.each { |site| record_uncertainty(site) if site.dynamic }
      record_uncertainty_at(node, context) if sites.empty? && unresolved_dynamic_dispatch?(node)

      visit_call_children(node, context, visit_block: !callback_block_consumed)
    end

    def visit_call_children(node, context, visit_receiver: true, visit_arguments: true, visit_block: true)
      visit(node.receiver, context) if visit_receiver && node.receiver
      arguments(node).each { |argument| visit(argument, context) } if visit_arguments
      visit(node.block, context) if visit_block && node.block
    end

    def visit_synthetic_body(body, context, purpose)
      return unless body

      synthetic = add_definition(
        symbol_id: "synthetic:#{purpose}:#{context.relative_file}:#{body.location.start_line}",
        kind: :block_entry,
        source_node: body,
        context: context,
        defined_via: purpose,
        owner: context.owner,
        name: purpose,
        visibility: :public
      )
      body_context = context.dup
      body_context.current_caller_id = synthetic.graph_id
      body_context.current_method_name = nil
      body_context.current_kind = :block_entry
      body_context.static_ancestry = false
      body_context.flow_result = nil
      visit(body, body_context)
      synthetic
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
      owner = singleton_class_owner(node.expression, context)
      unless owner
        visit(node.expression, context)
        record_semantic_blocker(
          :dynamic_singleton_definition,
          node,
          context,
          'singleton class receiver is not statically bounded',
          suggested_action: :make_singleton_receiver_static,
          force_global: true
        )
        return
      end

      singleton_context = context.dup
      singleton_context.namespace = owner
      singleton_context.owner = owner
      singleton_context.singleton_scope = true
      singleton_context.visibility = :public
      singleton_context.module_function = false
      visit(node.body, singleton_context)
    end

    def singleton_class_owner(expression, context)
      return context.owner if expression.is_a?(Prism::SelfNode)

      name = constant_name(expression)
      return unless name

      resolve_candidate_group(constant_candidates(name, context.lexical_nesting))
    end
  end
end
