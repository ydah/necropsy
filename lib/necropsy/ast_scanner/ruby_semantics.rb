# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def classify_receiver(receiver, context)
      return { kind: :implicit, name: nil } unless receiver
      return { kind: :self, name: context.owner } if receiver.is_a?(Prism::SelfNode)

      constant = constant_name(receiver)
      if constant
        candidates = constant_candidates(constant, context.namespace)
        return { kind: :constant, name: candidates.first, candidates: candidates }
      end

      if receiver.is_a?(Prism::CallNode) && receiver.name == :new
        receiver_constant = constant_name(receiver.receiver)
        if receiver_constant
          candidates = constant_candidates(receiver_constant, context.namespace)
          return { kind: :instance, name: candidates.first, candidates: candidates }
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
      data[:superclass_candidates] = constant_candidates(superclass, context.namespace) if superclass
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
