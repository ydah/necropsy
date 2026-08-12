# frozen_string_literal: true

require 'prism'

module Necropsy
  class FlowInterpreter
    DEFAULT_MAX_STEPS = 512
    MAX_ATOMS = 8
    class StepBudgetExceeded < StandardError; end
    ControlTransfer = Data.define(:kind, :fact)

    def initialize(constant_resolver:, max_steps: DEFAULT_MAX_STEPS)
      @constant_resolver = constant_resolver
      @max_steps = Integer(max_steps)
    end

    def analyze(body)
      @locals = {}
      @receiver_facts = {}.compare_by_identity
      @value_facts = {}.compare_by_identity
      @issues = []
      @return_facts = []
      @steps = 0
      value = evaluate(body)
      FlowResult.new(
        receiver_facts: @receiver_facts,
        value_facts: @value_facts,
        return_fact: return_fact(value),
        issues: @issues,
        steps: @steps
      )
    rescue StepBudgetExceeded
      FlowResult.new(
        receiver_facts: @receiver_facts,
        value_facts: @value_facts,
        return_fact: ValueFact.unknown(:step_budget),
        issues: [*@issues, 'step_budget'],
        steps: @steps
      )
    end

    private

    def evaluate(node)
      return ValueFact.unknown(:missing_value) unless node

      consume_step!
      value = case node
              when Prism::StatementsNode
                evaluate_statements(node)
              when Prism::EmbeddedStatementsNode
                evaluate(node.statements)
              when Prism::ParenthesesNode
                evaluate(node.body)
              when Prism::IfNode
                evaluate_if(node)
              when Prism::CaseNode
                evaluate_case(node)
              when Prism::ElseNode
                evaluate_clause(node)
              when Prism::WhenNode
                evaluate_when(node)
              when Prism::AndNode, Prism::OrNode
                evaluate_logical(node)
              when Prism::LocalVariableWriteNode
                assign_local(node)
              when Prism::LocalVariableReadNode
                @locals.fetch(node.name, ValueFact.unknown(:unbound_local))
              when Prism::CallNode
                evaluate_call(node)
              when Prism::ReturnNode
                evaluate_return(node)
              when Prism::BreakNode
                evaluate_transfer(node, :break)
              when Prism::NextNode
                evaluate_transfer(node, :next)
              when Prism::ArrayNode
                evaluate_array(node)
              when Prism::HashNode
                evaluate_hash(node)
              when Prism::LambdaNode, Prism::BlockNode
                evaluate_callable(node)
              when Prism::NilNode
                ValueFact.new(kind: :nil, exact: true, nilable: true, origin: :literal)
              when Prism::TrueNode, Prism::FalseNode
                ValueFact.new(kind: :boolean, values: [node.type.to_s.delete_suffix('_node')], origin: :literal)
              when Prism::SymbolNode
                ValueFact.new(kind: :symbol_set, values: [node.value.to_s], origin: :literal)
              when Prism::StringNode
                ValueFact.new(kind: :string_set, values: [node.content], origin: :literal)
              when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode
                evaluate_interpolated(node)
              when Prism::ConstantReadNode, Prism::ConstantPathNode
                class_object(node)
              else
                evaluate_unsupported(node)
              end
      @value_facts[node] = value.fact if transfer?(value)
      @value_facts[node] = value unless transfer?(value)
      value
    end

    def evaluate_statements(node)
      value = ValueFact.unknown(:empty_statements)
      node.body.each do |child|
        value = evaluate(child)
        break if transfer?(value)
      end
      value
    end

    def evaluate_clause(node)
      evaluate(node.statements)
    end

    def evaluate_if(node)
      predicate = evaluate(node.predicate)
      return predicate if transfer?(predicate)

      branches = [evaluate_branch(node.statements)]
      branches << (node.subsequent ? evaluate_branch(node.subsequent) : implicit_branch)
      join_branch_results(branches)
    end

    def evaluate_case(node)
      predicate = evaluate(node.predicate) if node.predicate
      return predicate if transfer?(predicate)

      branches = node.conditions.map { |condition| evaluate_branch(condition) }
      branches << if node.else_clause
                    evaluate_branch(node.else_clause)
                  else
                    implicit_branch
                  end
      join_branch_results(branches)
    end

    def evaluate_when(node)
      node.conditions.each do |condition|
        value = evaluate(condition)
        return value if transfer?(value)
      end
      evaluate(node.statements)
    end

    def evaluate_branch(branch)
      previous = @locals
      @locals = previous.dup
      value = evaluate(branch)
      [value, @locals, transfer?(value) ? value.kind : nil]
    ensure
      @locals = previous
    end

    def implicit_branch
      [nil_fact, @locals.dup, nil]
    end

    def join_branch_results(branches)
      normal_branches = branches.reject { |branch| branch[2] }
      return join_transfers(branches) if normal_branches.empty?

      values = normal_branches.map(&:first)
      branch_locals = normal_branches.map { |branch| branch[1] }
      names = branch_locals.flat_map(&:keys).uniq
      @locals = names.to_h do |name|
        join = join_facts(branch_locals.map { |locals| locals.fetch(name, ValueFact.unknown(:branch_unbound)) })
        [name, join]
      end
      join_facts(values)
    end

    def evaluate_logical(node)
      left = evaluate(node.left)
      return left if transfer?(left)

      right_branch = evaluate_branch(node.right)
      join_branch_results([[left, @locals.dup, nil], right_branch])
    end

    def assign_local(node)
      value = evaluate(node.value)
      return value if transfer?(value)

      @locals[node.name] = value
      value
    end

    def evaluate_call(node)
      receiver_fact = evaluate(node.receiver) if node.receiver
      return receiver_fact if transfer?(receiver_fact)

      arguments = Array(node.arguments&.arguments)
      arguments.each do |argument|
        argument_fact = evaluate(argument)
        return argument_fact if transfer?(argument_fact)
      end
      @receiver_facts[node.receiver] = receiver_fact if node.receiver
      return ControlTransfer.new(kind: :raise, fact: ValueFact.unknown(:raised)) if node.name == :raise && !node.receiver
      return transparent_wrapper(node) if transparent_wrapper?(node)
      return container_lookup(receiver_fact, arguments.first) if node.name == :[] && receiver_fact
      return callable_result(receiver_fact) if node.name == :call && receiver_fact
      return direct_constructor(node) if node.name == :new && receiver_fact&.kind == :class_object
      return concatenate_strings(receiver_fact, arguments.first) if node.name == :+ && receiver_fact

      ValueFact.unknown(:call_result)
    end

    def concatenate_strings(receiver_fact, argument)
      argument_fact = @value_facts[argument]
      return ValueFact.unknown(:dynamic_string_concat) unless receiver_fact.exact && argument_fact&.exact
      return ValueFact.unknown(:dynamic_string_concat) unless
        [receiver_fact.kind, argument_fact.kind].all? { |kind| %i[string_set symbol_set].include?(kind) }

      values = receiver_fact.values.product(argument_fact.values).map { |left, right| "#{left}#{right}" }
      return ValueFact.unknown(:string_product_budget) if values.length > MAX_ATOMS

      ValueFact.new(kind: :string_set, values: values, origin: :string_concat)
    end

    def evaluate_interpolated(node)
      parts = node.parts.map do |part|
        fact = evaluate(part)
        if part.is_a?(Prism::StringNode)
          [part.content.to_s]
        elsif fact.exact && %i[string_set symbol_set].include?(fact.kind)
          fact.values
        end
      end
      return ValueFact.unknown(:dynamic_interpolation) if parts.any?(&:nil?)

      values = parts.reduce(['']) do |prefixes, suffixes|
        next [] if prefixes.length * suffixes.length > MAX_ATOMS

        prefixes.product(suffixes).map { |prefix, suffix| "#{prefix}#{suffix}" }
      end
      return ValueFact.unknown(:string_product_budget) if values.empty? || values.length > MAX_ATOMS

      ValueFact.new(kind: :string_set, values: values, origin: :interpolation)
    end

    def transparent_wrapper?(node)
      node.receiver && constant_name(node.receiver) == 'T' && %i[let cast must unsafe].include?(node.name)
    end

    def transparent_wrapper(node)
      argument = Array(node.arguments&.arguments).first
      argument ? (@value_facts[argument] || evaluate(argument)) : ValueFact.unknown(:wrapper_argument)
    end

    def evaluate_return(node)
      argument = Array(node.arguments&.arguments).first
      value = argument ? evaluate(argument) : nil_fact
      return value if transfer?(value)

      @return_facts << value
      ControlTransfer.new(kind: :return, fact: value)
    end

    def evaluate_transfer(node, kind)
      argument = Array(node.arguments&.arguments).first
      value = argument ? evaluate(argument) : nil_fact
      return value if transfer?(value)

      ControlTransfer.new(kind: kind, fact: value)
    end

    def evaluate_array(node)
      elements = node.elements
      return ValueFact.unknown(:array_splat) if node.contains_splat?

      elements.each { |element| evaluate(element) }
      return ValueFact.unknown(:array_budget) if elements.length > MAX_ATOMS

      ValueFact.new(kind: :container, exact: true, origin: :literal_array,
                    summary: { 'type' => 'array', 'size' => elements.length })
    end

    def evaluate_hash(node)
      elements = node.elements
      return ValueFact.unknown(:hash_budget) if elements.length > MAX_ATOMS

      complete = true
      entries = { 'symbol' => {}, 'string' => {} }
      elements.each do |element|
        unless element.is_a?(Prism::AssocNode)
          complete = false
          evaluate_children(element)
          next
        end

        key = literal_key(element.key)
        value = evaluate(element.value)
        return value if transfer?(value)

        unless key
          complete = false
          evaluate(element.key)
          next
        end

        kind, key_value = key
        entries.fetch(kind)[key_value] = value.to_h
      end
      ValueFact.new(kind: :container, exact: complete, origin: :literal_hash,
                    summary: { 'type' => 'hash', 'size' => elements.length, 'entries' => entries })
    end

    def evaluate_callable(node)
      previous_returns = @return_facts
      @return_facts = []
      value, = evaluate_branch(node.body)
      value = return_fact(value)
      ValueFact.new(kind: :callable_set, values: ['block'], exact: true, origin: :literal_callable,
                    summary: { 'return_fact' => value.to_h })
    ensure
      @return_facts = previous_returns
    end

    def container_lookup(receiver_fact, argument)
      return ValueFact.unknown(:not_a_container) unless receiver_fact.kind == :container && receiver_fact.exact

      key_fact = @value_facts[argument]
      return ValueFact.unknown(:dynamic_container_key) unless
        key_fact&.exact && %i[symbol_set string_set].include?(key_fact.kind)

      kind = key_fact.kind == :symbol_set ? 'symbol' : 'string'
      entries = receiver_fact.summary&.dig('entries', kind) || {}
      values = key_fact.values.filter_map { |key| entries[key] }.map { |entry| ValueFact.from_h(entry) }
      return ValueFact.unknown(:missing_container_key) unless values.length == key_fact.values.length

      join_facts(values)
    end

    def callable_result(receiver_fact)
      return ValueFact.unknown(:not_callable) unless receiver_fact.kind == :callable_set

      return_fact = receiver_fact.summary&.fetch('return_fact', nil)
      return_fact.is_a?(Hash) ? ValueFact.from_h(return_fact) : ValueFact.unknown(:unknown_callable_return)
    end

    def literal_key(node)
      case node
      when Prism::SymbolNode
        ['symbol', node.value.to_s]
      when Prism::StringNode
        ['string', node.content.to_s]
      end
    end

    def evaluate_unsupported(node)
      written_names = local_writes(node)
      written_names.each { |name| @locals[name] = ValueFact.unknown(node.type) }
      evaluate_children(node)
      written_names.each { |name| @locals[name] = ValueFact.unknown(node.type) }
      ValueFact.unknown(node.type)
    end

    def evaluate_children(node)
      node.child_nodes.compact.each do |child|
        value = evaluate(child)
        break if transfer?(value)
      end
    end

    def local_writes(node)
      pending = [node]
      names = []
      until pending.empty?
        child = pending.pop
        names << child.name if child.type.to_s.match?(/\Alocal_variable_(?:.+_)?write_node\z/)
        pending.concat(child.child_nodes.compact)
      end
      names.uniq
    end

    def join_transfers(branches)
      kinds = branches.map { |branch| branch[2] }.uniq
      return ControlTransfer.new(kind: :unknown, fact: ValueFact.unknown(:mixed_control_transfer)) unless kinds.one?

      ControlTransfer.new(kind: kinds.first, fact: join_facts(branches.map(&:first).map(&:fact)))
    end

    def transfer?(value)
      value.is_a?(ControlTransfer)
    end

    def return_fact(value)
      normal_value = transfer?(value) ? nil : value
      facts = [*@return_facts, normal_value].compact
      return value.fact if facts.empty? && transfer?(value)
      return facts.first if facts.one?

      join_facts(facts)
    end

    def nil_fact
      ValueFact.new(kind: :nil, exact: true, nilable: true, origin: :implicit_nil)
    end

    def join_facts(facts)
      facts = Array(facts).compact
      return ValueFact.unknown(:empty_join) if facts.empty?
      return ValueFact.unknown(:unknown_join) if facts.any? { |fact| fact.kind == :unknown || !fact.exact }

      kinds = facts.map(&:kind).uniq
      return ValueFact.unknown(:mixed_join) unless kinds.one?

      values = facts.flat_map(&:values).uniq.sort
      return ValueFact.unknown(:atom_budget) if values.length > MAX_ATOMS

      ValueFact.new(
        kind: kinds.first,
        values: values,
        exact: true,
        nilable: facts.any?(&:nilable),
        origin: :branch_join,
        summary: facts.map(&:summary).compact.uniq.one? ? facts.first.summary : nil
      )
    end

    def class_object(node)
      name = constant_name(node)
      return ValueFact.unknown(:dynamic_constant) unless name

      ValueFact.new(kind: :class_object, values: [@constant_resolver.call(name)], origin: :constant)
    end

    def direct_constructor(node)
      owner = constant_name(node.receiver)
      return ValueFact.unknown(:dynamic_constructor) unless owner

      ValueFact.instance_types([@constant_resolver.call(owner)])
    end

    def constant_name(node)
      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        prefix = node.parent ? constant_name(node.parent) : ''
        [prefix, node.name.to_s].join('::')
      end
    end

    def consume_step!
      @steps += 1
      raise StepBudgetExceeded if @steps > @max_steps
    end
  end
end
