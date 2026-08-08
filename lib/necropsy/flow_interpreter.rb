# frozen_string_literal: true

require 'prism'

module Necropsy
  class FlowInterpreter
    DEFAULT_MAX_STEPS = 512
    MAX_ATOMS = 8
    class StepBudgetExceeded < StandardError; end

    def initialize(constant_resolver:, max_steps: DEFAULT_MAX_STEPS)
      @constant_resolver = constant_resolver
      @max_steps = Integer(max_steps)
    end

    def analyze(body)
      @locals = {}
      @receiver_facts = {}.compare_by_identity
      @value_facts = {}.compare_by_identity
      @issues = []
      @steps = 0
      value = evaluate(body)
      FlowResult.new(
        receiver_facts: @receiver_facts,
        value_facts: @value_facts,
        return_fact: value,
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
              when Prism::IfNode
                evaluate_if(node)
              when Prism::CaseNode
                evaluate_case(node)
              when Prism::ElseNode, Prism::WhenNode
                evaluate_clause(node)
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
              when Prism::ArrayNode
                evaluate_array(node)
              when Prism::HashNode
                evaluate_hash(node)
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
                ValueFact.unknown(node.type)
              end
      @value_facts[node] = value
      value
    end

    def evaluate_statements(node)
      value = ValueFact.unknown(:empty_statements)
      node.body.each { |child| value = evaluate(child) }
      value
    end

    def evaluate_clause(node)
      evaluate(node.statements)
    end

    def evaluate_if(node)
      evaluate(node.predicate)
      branches = [evaluate_branch(node.statements)]
      branches << evaluate_branch(node.subsequent) if node.subsequent
      join_branch_results(branches)
    end

    def evaluate_case(node)
      evaluate(node.predicate) if node.predicate
      branches = node.conditions.map { |condition| evaluate_branch(condition) }
      branches << evaluate_branch(node.else_clause) if node.else_clause
      join_branch_results(branches)
    end

    def evaluate_branch(branch)
      previous = @locals
      @locals = previous.dup
      value = evaluate(branch)
      [value, @locals]
    ensure
      @locals = previous
    end

    def join_branch_results(branches)
      values = branches.map(&:first)
      branch_locals = branches.map(&:last)
      names = branch_locals.flat_map(&:keys).uniq
      @locals = names.to_h do |name|
        join = join_facts(branch_locals.map { |locals| locals.fetch(name, ValueFact.unknown(:branch_unbound)) })
        [name, join]
      end
      join_facts(values)
    end

    def evaluate_logical(node)
      left = evaluate(node.left)
      right = evaluate(node.right)
      join_facts([left, right])
    end

    def assign_local(node)
      value = evaluate(node.value)
      @locals[node.name] = value
      value
    end

    def evaluate_call(node)
      receiver_fact = evaluate(node.receiver) if node.receiver
      arguments = Array(node.arguments&.arguments)
      arguments.each { |argument| evaluate(argument) }
      @receiver_facts[node.receiver] = receiver_fact if node.receiver
      return transparent_wrapper(node) if transparent_wrapper?(node)
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
      argument ? evaluate(argument) : ValueFact.unknown(:return_nil)
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

      elements.each { |element| evaluate(element) }
      ValueFact.new(kind: :container, exact: true, origin: :literal_hash,
                    summary: { 'type' => 'hash', 'size' => elements.length })
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
