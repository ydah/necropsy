# frozen_string_literal: true

require 'prism'

module Necropsy
  ScanResult = Data.define(:nodes, :call_sites, :instantiated_classes, :uncertainties, :class_infos, :entrypoint_hints)

  class AstScanner
    ATTR_MACROS = %i[attr_reader attr_writer attr_accessor].freeze
    DYNAMIC_SENDS = %i[send public_send __send__].freeze
    MODULE_RELATION_MACROS = %i[include prepend extend].freeze
    RAILS_CALLBACK_MACROS = %i[
      before_action after_action around_action
      before_save after_save before_create after_create before_update after_update
      before_destroy after_destroy around_save validate
    ].freeze

    Context = Struct.new(
      :namespace,
      :owner,
      :current_caller_id,
      :current_kind,
      :root_id,
      :file,
      :relative_file,
      :test,
      :singleton_scope,
      keyword_init: true
    )

    def initialize(project:, files:)
      @project = project
      @files = files
      @nodes = []
      @call_sites = []
      @instantiated_classes = Set.new
      @uncertainties = Hash.new { |hash, key| hash[key] = [] }
      @class_data = {}
      @entrypoint_hints = []
    end

    def scan
      files.each { |file| scan_file(file) }
      ScanResult.new(
        nodes: nodes.uniq(&:id),
        call_sites: call_sites,
        instantiated_classes: instantiated_classes,
        uncertainties: uncertainties,
        class_infos: class_infos,
        entrypoint_hints: entrypoint_hints.uniq
      )
    end

    private

    attr_reader :project, :files, :nodes, :call_sites, :instantiated_classes, :uncertainties, :class_data,
                :entrypoint_hints

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
        test: test
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
          singleton_scope: false
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
        test: context.test
      )
      if node.name == :method_missing
        uncertainties[id] << "#{owner} defines method_missing"
        class_record(owner)[:dynamic] = true
      end

      method_context = context.dup
      method_context.owner = owner
      method_context.current_caller_id = id
      method_context.current_kind = kind
      method_context.singleton_scope = false
      visit(node.body, method_context)
    end

    def visit_call(node, context)
      return if handle_define_method(node, context)
      return if handle_attr_macro(node, context)
      return if handle_delegate(node, context)
      return if handle_alias_method(node, context)

      handle_module_relation(node, context)
      handle_rails_callback(node, context)

      record_instantiation(node, context)
      site = build_call_site(node, context)
      call_sites << site if site
      if site&.dynamic
        record_uncertainty(site)
      elsif unresolved_dynamic_dispatch?(node)
        record_uncertainty_at(node, context)
      end

      visit_children(node, context)
    end

    def visit_singleton_class(node, context)
      return visit_children(node, context) unless node.expression.is_a?(Prism::SelfNode) && context.owner

      singleton_context = context.dup
      singleton_context.singleton_scope = true
      visit(node.body, singleton_context)
    end

    def visit_constant_write(node, context)
      return visit_children(node, context) unless struct_or_data_definition?(node.value)

      owner = qualify_constant(node.name.to_s, context.namespace)
      data = class_record(owner)
      data[:kind] = :class
      data[:file] = context.relative_file
      data[:line] = node.location.start_line
      instantiated_classes << owner

      symbol_arguments(node.value).each do |name|
        nodes << Node.new(
          id: "#{owner}##{name}",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.value.name == :define ? :data_define : :struct_new,
          owner: owner,
          name: name,
          test: context.test
        )
        next if node.value.name == :define

        nodes << Node.new(
          id: "#{owner}##{name}=",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: :struct_new,
          owner: owner,
          name: "#{name}=",
          test: context.test
        )
      end

      return unless node.value.block

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = false
      visit(node.value.block.body, block_context)
    end

    def struct_or_data_definition?(value)
      return false unless value.is_a?(Prism::CallNode)

      receiver_name = constant_name(value.receiver)
      (receiver_name == 'Struct' && value.name == :new) || (receiver_name == 'Data' && value.name == :define)
    end

    def visit_children(node, context)
      node.child_nodes.compact.each { |child| visit(child, context) }
    end

    def handle_define_method(node, context)
      return false unless node.name == :define_method
      return false unless context.owner

      method_name = first_symbol_argument(node)
      return false unless method_name

      id = "#{context.owner}##{method_name}"
      nodes << Node.new(
        id: id,
        kind: :instance_method,
        file: context.relative_file,
        line: node.location.start_line,
        end_line: node.location.end_line,
        defined_via: :define_method,
        owner: context.owner,
        name: method_name,
        test: context.test
      )

      if node.block
        block_context = context.dup
        block_context.current_caller_id = id
        block_context.current_kind = :instance_method
        visit(node.block.body, block_context)
      end
      true
    end

    def handle_alias_method(node, context)
      return false unless node.name == :alias_method
      return false unless context.owner

      new_name, old_name = symbol_arguments(node)
      return false unless new_name && old_name

      record_alias_method(context, node.location, new_name, old_name)
      true
    end

    def visit_alias_method_node(node, context)
      return visit_children(node, context) unless context.owner

      new_name = node.new_name.unescaped.to_s
      old_name = node.old_name.unescaped.to_s
      record_alias_method(context, node.location, new_name, old_name)
    end

    def record_alias_method(context, location, new_name, old_name)
      kind = context.singleton_scope ? :singleton_method : :instance_method
      separator = kind == :singleton_method ? '.' : '#'
      id = "#{context.owner}#{separator}#{new_name}"
      nodes << Node.new(
        id: id,
        kind: kind,
        file: context.relative_file,
        line: location.start_line,
        end_line: location.end_line,
        defined_via: :alias_method,
        owner: context.owner,
        name: new_name,
        test: context.test
      )
      call_sites << CallSite.new(
        caller_id: id,
        message: old_name,
        receiver_kind: :self,
        receiver_name: context.owner,
        file: context.relative_file,
        line: location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'original_message' => old_name, 'alias_method' => true }
      )
    end

    def handle_module_relation(node, context)
      return unless MODULE_RELATION_MACROS.include?(node.name)
      return unless context.owner

      constants = arguments(node).filter_map { |argument| constant_name(argument) }
      return if constants.empty?

      data = class_record(context.owner)
      key = :"#{node.name}s"
      constants.each { |constant| data[key].concat(constant_candidates(constant, context.namespace)) }
    end

    def handle_rails_callback(node, context)
      return unless RAILS_CALLBACK_MACROS.include?(node.name)
      return unless context.owner

      symbol_arguments(node).each do |method_name|
        entrypoint_hints << EntryPoint.new(node_id: "#{context.owner}##{method_name}", reason: :callback_registered)
      end
    end

    def handle_attr_macro(node, context)
      return false unless ATTR_MACROS.include?(node.name)
      return false unless context.owner

      symbol_arguments(node).each do |name|
        nodes << Node.new(
          id: "#{context.owner}##{name}",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: name,
          test: context.test
        )
        next unless %i[attr_writer attr_accessor].include?(node.name)

        nodes << Node.new(
          id: "#{context.owner}##{name}=",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: "#{name}=",
          test: context.test
        )
      end
      true
    end

    def handle_delegate(node, context)
      return false unless node.name == :delegate
      return false unless context.owner

      symbol_arguments(node).each do |name|
        nodes << Node.new(
          id: "#{context.owner}##{name}",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: :delegate,
          owner: context.owner,
          name: name,
          test: context.test
        )
      end
      true
    end

    def build_call_site(node, context)
      message = node.name&.to_s
      dynamic = false
      receiver = classify_receiver(node.receiver, context)
      metadata = { 'original_message' => message, 'receiver_candidates' => receiver[:candidates] }

      if DYNAMIC_SENDS.include?(node.name)
        literal = first_symbol_argument(node) || first_string_argument(node)
        dynamic = literal.nil?
        message = literal
        metadata['dynamic_dispatch'] = true
      end

      return nil unless message

      CallSite.new(
        caller_id: context.current_caller_id,
        message: message,
        receiver_kind: receiver.fetch(:kind),
        receiver_name: receiver[:name],
        file: context.relative_file,
        line: node.location.start_line,
        test: context.test,
        dynamic: dynamic,
        metadata: metadata
      )
    end

    def record_instantiation(node, context)
      return record_factory_instantiation(node, context) unless %i[new []].include?(node.name)

      receiver = classify_receiver(node.receiver, context)
      return unless receiver[:kind] == :constant

      Array(receiver[:candidates] || receiver[:name]).each { |name| instantiated_classes << name }
      record_initialize_call(node, context, receiver)
    end

    def record_initialize_call(node, context, receiver)
      return unless node.name == :new

      call_sites << CallSite.new(
        caller_id: context.current_caller_id,
        message: 'initialize',
        receiver_kind: :instance,
        receiver_name: receiver[:name],
        file: context.relative_file,
        line: node.location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'original_message' => 'new', 'receiver_candidates' => receiver[:candidates],
                    'implicit_from' => 'new' }
      )
    end

    def record_factory_instantiation(node, context)
      factory_methods = Array(project.config.factory_methods).map(&:to_s)
      return unless factory_methods.include?(node.name.to_s)

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

    def record_parse_errors(root_id, result)
      result.errors.each do |error|
        uncertainties[root_id] << "Parse warning at line #{error.location.start_line}: #{error.message}"
      end
    end

    def definition_owner(node, context)
      return context.owner unless node.receiver
      return context.owner if node.receiver.is_a?(Prism::SelfNode)

      receiver = classify_receiver(node.receiver, context)
      receiver[:name]
    end

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
      arguments(node).find { |arg| arg.respond_to?(:unescaped) && arg.class.name.end_with?('StringNode') }&.unescaped
    end

    def symbol_arguments(node)
      arguments(node).filter_map do |arg|
        next unless arg.respond_to?(:unescaped) && arg.class.name.end_with?('SymbolNode')

        arg.unescaped.to_s
      end
    end

    def arguments(node)
      node.arguments&.arguments || []
    end

    def constant_name(node)
      return nil unless node

      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        [constant_name(node.parent), node.name.to_s].compact.join('::')
      end
    end

    def qualify_constant(name, namespace)
      return nil unless name
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
        ClassInfo.new(
          id: data.fetch(:id),
          kind: data.fetch(:kind),
          file: data[:file],
          line: data[:line],
          superclass: resolve_known_constants(data.fetch(:superclass_candidates)).first,
          superclass_candidates: data.fetch(:superclass_candidates),
          includes: resolve_known_constants(data.fetch(:includes)),
          prepends: resolve_known_constants(data.fetch(:prepends)),
          extends: resolve_known_constants(data.fetch(:extends)),
          dynamic: data.fetch(:dynamic)
        )
      end
    end

    def resolve_known_constants(candidates)
      grouped_candidates(candidates).map do |group|
        group.find { |candidate| class_data.key?(candidate) } || group.first
      end.compact.uniq
    end

    def grouped_candidates(candidates)
      Array(candidates).chunk_while do |left, right|
        suffix = left.split('::').last
        right&.end_with?("::#{suffix}") || right == suffix
      end.to_a
    end

    def constant_candidates(name, namespace)
      return [name] if namespace.nil? || namespace.empty? || name.include?('::')

      parts = namespace.split('::')
      candidates = []
      parts.length.downto(1) do |length|
        candidates << "#{parts.first(length).join('::')}::#{name}"
      end
      candidates << name
      candidates.uniq
    end
  end
end
