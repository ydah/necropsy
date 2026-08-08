# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def build_call_sites(node, context)
      messages = finite_dynamic_messages(node, context)
      return [build_call_site(node, context)] if messages.empty?

      messages.map { |message| build_call_site(node, context, message_override: message) }
    end

    def build_call_site(node, context, message_override: nil)
      message = node.name&.to_s
      dynamic = false
      receiver = classify_receiver(node.receiver, context)
      metadata = { 'original_message' => message, 'receiver_candidates' => receiver[:candidates] }
      metadata['arguments'] = call_arguments(node, offset: DYNAMIC_SENDS.include?(node.name) ? 1 : 0)
      receiver_fact = context.flow_result&.fact_for(node.receiver)
      compact_receiver_fact = compact_receiver_fact(receiver_fact)
      metadata['receiver_value_fact'] = compact_receiver_fact if compact_receiver_fact

      if DYNAMIC_SENDS.include?(node.name)
        literal = first_symbol_argument(node) || first_string_argument(node)
        message = message_override || literal
        dynamic = message.nil?
        metadata['dynamic_dispatch'] = true
        metadata['finite_dynamic_dispatch'] = true if message_override
      end

      return nil unless message

      scanned_call_site(
        source_node: node,
        context: context,
        role: :call,
        message: message,
        receiver_kind: receiver.fetch(:kind),
        receiver_name: receiver[:name],
        dynamic: dynamic,
        metadata: metadata
      )
    end

    def finite_dynamic_messages(node, context)
      return [] unless DYNAMIC_SENDS.include?(node.name)
      return [] if first_symbol_argument(node) || first_string_argument(node)

      argument = Array(node.arguments&.arguments).first
      fact = context.flow_result&.fact_for(argument)
      return [] unless fact&.exact && %i[symbol_set string_set].include?(fact.kind)

      Array(fact.values).map(&:to_s).uniq.sort.first(FlowInterpreter::MAX_ATOMS)
    end

    def compact_receiver_fact(fact)
      return unless fact&.exact
      return unless %i[instance_types callable_set].include?(fact.kind)

      fact.to_h.merge('summary' => nil)
    end

    def record_instantiation(node, context)
      return record_factory_instantiation(node, context) unless %i[new []].include?(node.name)

      receiver = classify_receiver(node.receiver, context)
      receiver = implicit_self_constructor(context) if implicit_constructor?(receiver, context)
      return unless receiver && receiver[:kind] == :constant

      Array(receiver[:candidates] || receiver[:name]).each { |name| instantiated_classes << name }
      record_initialize_call(node, context, receiver)
    end

    def implicit_constructor?(receiver, context)
      return false unless %i[implicit self].include?(receiver[:kind])
      return false unless context.owner

      context.current_kind == :singleton_method || context.current_caller_id == context.root_id
    end

    def implicit_self_constructor(context)
      { kind: :constant, name: context.owner, candidates: [context.owner] }
    end

    def record_initialize_call(node, context, receiver)
      return unless node.name == :new

      add_scanned_call_site(
        source_node: node,
        context: context,
        role: :initialize,
        message: 'initialize',
        receiver_kind: :instance,
        receiver_name: receiver[:name],
        dynamic: false,
        metadata: { 'original_message' => 'new', 'receiver_candidates' => receiver[:candidates],
                    'implicit_from' => 'new', 'arguments' => call_arguments(node) }
      )
    end

    def record_factory_instantiation(node, context)
      return unless @factory_methods.include?(node.name.to_s)

      receiver = classify_receiver(node.receiver, context)
      return unless receiver[:kind] == :constant

      Array(receiver[:candidates] || receiver[:name]).each do |name|
        instantiated_classes << name
      end
    end

    def record_uncertainty(site)
      uncertainties[site.caller_id] << "Dynamic dispatch at #{site.file}:#{site.line}"
    end

    def record_uncertainty_at(node, context)
      uncertainties[context.current_caller_id] << "Dynamic dispatch at #{context.relative_file}:#{node.location.start_line}"
    end

    def unresolved_dynamic_dispatch?(node)
      DYNAMIC_SENDS.include?(node.name) && first_symbol_argument(node).nil? && first_string_argument(node).nil?
    end

    def record_parse_errors(root_id, relative, result)
      result.errors.each do |error|
        uncertainties[root_id] << "Parse warning at line #{error.location.start_line}: #{error.message}"
        source_errors << SourceError.new(
          file: relative,
          line: error.location.start_line,
          message: error.message,
          type: error.type
        )
      end
    end

    def record_source_failure(root_id, relative, error)
      file_statuses[relative] = :failed
      uncertainties[root_id] << "Could not parse #{relative}: #{error.message}"
      source_errors << SourceError.new(
        file: relative,
        line: 1,
        message: error.message,
        type: error.class.name.to_sym
      )
    end

    def definition_owner(node, context)
      return context.owner unless node.receiver
      return context.owner if node.receiver.is_a?(Prism::SelfNode)

      receiver = classify_receiver(node.receiver, context)
      receiver[:name]
    end

    def definition_owner_for_call(node, context)
      return context.owner unless node.receiver
      return context.owner if node.receiver.is_a?(Prism::SelfNode)

      classify_receiver(node.receiver, context)[:name]
    end

    def eval_owner(node, context)
      return context.owner unless node.receiver

      definition_owner_for_call(node, context)
    end

    def method_kind_and_separator(context)
      context.singleton_scope ? [:singleton_method, '.'] : [:instance_method, '#']
    end

    def update_method_visibility(context, name, visibility, singleton: false)
      separator = singleton ? '.' : method_kind_and_separator(context).last
      id = "#{context.owner}#{separator}#{name}"
      index = nodes.rindex { |candidate| candidate.id == id }
      nodes[index] = nodes[index].with(visibility: visibility) if index
    end

    def defer_module_function(context, name, source_node)
      instance_id = "#{context.owner}##{name}"
      privatize_current_module_function_source(instance_id, context.relative_file)
      copy = add_module_function_definition(context, name, source_node)
      deferred_module_functions[copy.graph_id] = instance_id
    end

    def privatize_current_module_function_source(instance_id, relative_file)
      index = nodes.rindex do |definition|
        definition.kind == :instance_method && definition.symbol_id == instance_id && definition.file == relative_file
      end
      nodes[index] = nodes[index].with(visibility: :private) if index
    end

    def add_module_function_definition(context, name, source_node)
      add_definition(
        symbol_id: "#{context.owner}.#{name}",
        kind: :singleton_method,
        source_node: source_node,
        context: context,
        defined_via: :module_function,
        owner: context.owner,
        name: name,
        visibility: :public
      )
    end
  end
end
