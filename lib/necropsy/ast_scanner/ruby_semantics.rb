# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def classify_receiver(receiver, context)
      return { kind: :implicit, name: context.owner, candidates: [context.owner].compact } unless receiver
      return { kind: :self, name: context.owner, candidates: [context.owner].compact } if receiver.is_a?(Prism::SelfNode)

      constant = constant_name(receiver)
      if constant
        candidates = constant_candidates(constant, context.namespace)
        return { kind: :constant, name: resolve_candidate_group(candidates), candidates: candidates }
      end

      if receiver.is_a?(Prism::CallNode) && receiver.name == :new
        receiver_constant = constant_name(receiver.receiver)
        if receiver_constant
          candidates = constant_candidates(receiver_constant, context.namespace)
          return { kind: :instance, name: resolve_candidate_group(candidates), candidates: candidates }
        end
      end

      { kind: :unknown, name: nil, candidates: [] }
    end

    def first_symbol_argument(node)
      symbol_arguments(node).first
    end

    def first_string_argument(node)
      arguments(node).find { |argument| argument.is_a?(Prism::StringNode) }&.unescaped
    end

    def literal_argument(node, index:)
      argument = arguments(node)[index]
      return unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

      argument.unescaped.to_s
    end

    def symbol_arguments(node)
      arguments(node).filter_map do |arg|
        next unless arg.is_a?(Prism::SymbolNode)

        arg.unescaped.to_s
      end
    end

    def arguments(node)
      node.arguments&.arguments || []
    end

    def keyword_value(node, key)
      hash = arguments(node).find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      pair = hash&.elements&.find do |element|
        element.is_a?(Prism::AssocNode) && literal_value(element.key).to_s == key
      end
      literal_value(pair&.value)
    end

    def keyword_keys(node)
      hash = arguments(node).find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      Array(hash&.elements).filter_map do |element|
        literal_value(element.key).to_s if element.is_a?(Prism::AssocNode)
      end
    end

    def literal_value(node)
      case node
      when Prism::SymbolNode, Prism::StringNode
        node.unescaped.to_s
      when Prism::TrueNode
        true
      when Prism::FalseNode
        false
      end
    end

    def method_signature(parameters)
      return { 'complete' => false } unless parameters

      forwarding = parameters.child_nodes.compact.any? { |parameter| parameter.type == :forwarding_parameter_node }
      keywords = Array(parameters.keywords)
      keyword_rest = parameters.keyword_rest
      no_keywords = !keyword_rest.nil? && keyword_rest.type == :no_keywords_parameter_node
      accepts_keywords = keywords.any? || (!keyword_rest.nil? && !no_keywords)
      {
        'complete' => !forwarding,
        'minimum_positionals' => Array(parameters.requireds).length + Array(parameters.posts).length,
        'maximum_positionals' => if parameters.rest
                                   nil
                                 else
                                   Array(parameters.requireds).length +
                                     Array(parameters.optionals).length + Array(parameters.posts).length
                                 end,
        'required_keywords' => keywords.select do |parameter|
          parameter.type == :required_keyword_parameter_node
        end.map { |parameter| parameter.name.to_s }.sort,
        'accepted_keywords' => keywords.map { |parameter| parameter.name.to_s }.sort,
        'accepts_keywords' => accepts_keywords,
        'no_keywords' => no_keywords,
        'keyword_rest' => !keyword_rest.nil? && !no_keywords
      }
    end

    def call_arguments(node, offset: 0)
      values = Array(node.arguments&.arguments).drop(offset)
      keyword_hash = values.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      positional = values.grep_v(Prism::KeywordHashNode)
      keyword_elements = Array(keyword_hash&.elements)
      {
        'complete' => positional.none? do |argument|
          %i[splat_node forwarding_arguments_node].include?(argument.type)
        end && keyword_elements.none? { |element| element.type == :assoc_splat_node },
        'positional_count' => positional.length,
        'keywords' => keyword_elements.filter_map do |element|
          literal_value(element.key).to_s if element.is_a?(Prism::AssocNode)
        end.sort
      }
    end

    def incomplete_arguments
      { 'complete' => false, 'positional_count' => 0, 'keywords' => [] }
    end

    def constant_name(node)
      return nil unless node

      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        prefix = node.parent ? constant_name(node.parent) : ''
        [prefix, node.name.to_s].join('::')
      end
    end

    def qualify_constant(name, namespace)
      return nil unless name
      return name.delete_prefix('::') if name.start_with?('::')
      return name if namespace.nil? || namespace.empty? || name.include?('::')

      "#{namespace}::#{name}"
    end

    def record_class_info(node, namespace, context)
      return unless namespace

      data = class_record(namespace)
      data[:kind] = node.is_a?(Prism::ModuleNode) ? :module : :class
      data[:file] = context.relative_file
      data[:line] = node.location.start_line
      return unless node.respond_to?(:superclass)

      superclass = constant_name(node.superclass)
      if superclass
        data[:superclass_candidates] = constant_candidates(superclass, context.namespace)
      elsif data[:superclass_candidates].empty?
        data[:superclass_candidates] = implicit_superclass_candidates(namespace)
      end
    end

    def implicit_superclass_candidates(namespace)
      return [] if namespace == 'BasicObject'
      return ['BasicObject'] if namespace == 'Object'

      ['Object']
    end

    def class_record(namespace)
      class_data[namespace] ||= {
        id: namespace,
        kind: :class,
        file: nil,
        line: nil,
        superclass: nil,
        superclass_candidates: [],
        includes: [],
        prepends: [],
        extends: [],
        singleton_includes: [],
        singleton_prepends: [],
        dynamic: false
      }
    end

    def class_infos
      class_data.values.map do |data|
        superclass_candidates = data.fetch(:superclass_candidates)
        ClassInfo.new(
          id: data.fetch(:id),
          kind: data.fetch(:kind),
          file: data[:file],
          line: data[:line],
          superclass: resolve_candidate_group(superclass_candidates),
          superclass_candidates: superclass_candidates,
          includes: resolve_candidate_groups(data.fetch(:includes)),
          prepends: resolve_candidate_groups(data.fetch(:prepends)),
          extends: resolve_candidate_groups(data.fetch(:extends)),
          singleton_includes: resolve_candidate_groups(data.fetch(:singleton_includes)),
          singleton_prepends: resolve_candidate_groups(data.fetch(:singleton_prepends)),
          dynamic: data.fetch(:dynamic)
        )
      end
    end

    def resolve_candidate_groups(groups)
      Array(groups).filter_map { |group| resolve_candidate_group(Array(group)) }.uniq
    end

    def resolve_candidate_group(group)
      group.find { |candidate| class_data.key?(candidate) } || group.first
    end

    def constant_candidates(name, namespace)
      return [name.delete_prefix('::')] if name.start_with?('::')
      return [name] if namespace.nil? || namespace.empty?

      head, *rest = name.split('::')
      suffix = rest.empty? ? '' : "::#{rest.join('::')}"
      parts = namespace.split('::')
      candidates = []
      parts.length.downto(1) do |length|
        candidates << "#{parts.first(length).join('::')}::#{head}#{suffix}"
      end
      inherited_namespaces(namespace).each do |ancestor|
        candidates << "#{ancestor}::#{head}#{suffix}"
      end
      candidates << name
      candidates.uniq
    end

    def inherited_namespaces(namespace, seen = Set.new)
      return [] unless namespace && seen.add?(namespace)

      data = class_data[namespace]
      return [] unless data

      Array(data[:superclass_candidates]).flat_map do |superclass|
        [superclass, *inherited_namespaces(superclass, seen)]
      end.uniq
    end
  end
end
