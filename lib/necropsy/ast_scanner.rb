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
      before_validation after_validation before_save after_save around_save
      around_validation before_touch after_touch
      before_create after_create around_create before_update after_update around_update
      before_destroy after_destroy around_destroy after_commit after_rollback after_initialize after_find
      after_create_commit after_update_commit after_destroy_commit after_save_commit
      validate rescue_from helper_method
    ].freeze
    VISIBILITY_MACROS = %i[public protected private public_class_method private_class_method].freeze
    SYMBOL_REFERENCE_CALLS = %i[method respond_to? try try!].freeze
    RAILS_BUILTIN_VALIDATORS = %w[
      absence acceptance allow_blank allow_nil comparison confirmation exclusion format if inclusion length message numericality
      on presence strict uniqueness unless
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
      :visibility,
      :module_function,
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
      @factory_methods = project.config.factory_methods.to_set(&:to_s)
    end

    def scan
      files.each { |file| scan_file(file) }
      copy_module_function_call_sites
      ScanResult.new(
        nodes: nodes.reverse.uniq(&:id).reverse,
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
          test: context.test,
          visibility: :public
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
          test: context.test,
          visibility: :public
        )
      end

      return unless node.value.block

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = false
      block_context.visibility = :public
      block_context.module_function = false
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

      kind, separator = method_kind_and_separator(context)
      id = "#{context.owner}#{separator}#{method_name}"
      nodes << Node.new(
        id: id,
        kind: kind,
        file: context.relative_file,
        line: node.location.start_line,
        end_line: node.location.end_line,
        defined_via: :define_method,
        owner: context.owner,
        name: method_name,
        test: context.test,
        visibility: context.visibility
      )
      record_module_function_copy(node, context, context.owner, method_name) if context.module_function

      if node.block
        block_context = context.dup
        block_context.current_caller_id = id
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
      nodes << Node.new(
        id: id,
        kind: :singleton_method,
        file: context.relative_file,
        line: node.location.start_line,
        end_line: node.location.end_line,
        defined_via: :define_singleton_method,
        owner: owner,
        name: method_name,
        test: context.test,
        visibility: :public
      )
      if node.block
        block_context = context.dup
        block_context.owner = owner
        block_context.current_caller_id = id
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
        names.each { |name| promote_module_function(context, name, node.location) }
      end
      true
    end

    def record_module_function_copy(node, context, _owner, method_name = node.name.to_s)
      promote_module_function(context, method_name, node.location)
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
        test: context.test,
        visibility: context.visibility
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

      class_record(context.owner)[:extends] << [context.owner] if node.name == :extend && arguments(node).any?(Prism::SelfNode)

      constants = arguments(node).filter_map { |argument| constant_name(argument) }
      return if constants.empty?

      data = class_record(context.owner)
      key = :"#{node.name}s"
      constants.each { |constant| data[key] << constant_candidates(constant, context.namespace) }
    end

    def handle_rails_callback(node, context)
      return unless context.owner
      return if context.test

      if RAILS_CALLBACK_MACROS.include?(node.name)
        callback_names(node).each do |method_name|
          entrypoint_hints << EntryPoint.new(node_id: "#{context.owner}##{method_name}", reason: :callback_registered)
        end
      elsif node.name == :validates
        custom_validator_names(node).each do |validator|
          constant_candidates("#{validator}Validator", context.namespace).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate_each", reason: :callback_registered)
          end
        end
      elsif node.name == :validates_with
        arguments(node).filter_map { |argument| constant_name(argument) }.each do |validator|
          constant_candidates(validator, context.namespace).each do |owner|
            entrypoint_hints << EntryPoint.new(node_id: "#{owner}#validate", reason: :callback_registered)
          end
        end
      end
    end

    def handle_attr_macro(node, context)
      return false unless ATTR_MACROS.include?(node.name)
      return false unless context.owner

      symbol_arguments(node).each do |name|
        kind, separator = method_kind_and_separator(context)
        nodes << Node.new(
          id: "#{context.owner}#{separator}#{name}",
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: name,
          test: context.test,
          visibility: context.visibility
        )
        next unless %i[attr_writer attr_accessor].include?(node.name)

        nodes << Node.new(
          id: "#{context.owner}#{separator}#{name}=",
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: "#{name}=",
          test: context.test,
          visibility: context.visibility
        )
      end
      true
    end

    def handle_delegate(node, context)
      return false unless node.name == :delegate
      return false unless context.owner

      target = keyword_value(node, 'to')
      prefix = keyword_value(node, 'prefix')
      symbol_arguments(node).each do |name|
        generated_name = delegated_method_name(name, target, prefix)
        kind, separator = method_kind_and_separator(context)
        id = "#{context.owner}#{separator}#{generated_name}"
        nodes << Node.new(
          id: id,
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: :delegate,
          owner: context.owner,
          name: generated_name,
          test: context.test,
          visibility: context.visibility
        )
        record_delegate_target(id, target, node, context) if target
        record_delegated_message(id, name, node, context)
      end
      true
    end

    def handle_forwardable(node, context)
      return false unless %i[def_delegator def_delegators].include?(node.name)
      return false unless context.owner

      symbols = symbol_arguments(node)
      return false if symbols.length < 2

      target = symbols.shift
      definitions = if node.name == :def_delegator
                      [[symbols[1] || symbols[0], symbols[0]]]
                    else
                      symbols.map { |name| [name, name] }
                    end
      definitions.each do |generated_name, delegated_name|
        kind, separator = method_kind_and_separator(context)
        id = "#{context.owner}#{separator}#{generated_name}"
        nodes << Node.new(
          id: id,
          kind: kind,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.name,
          owner: context.owner,
          name: generated_name,
          test: context.test,
          visibility: context.visibility
        )
        record_delegate_target(id, target, node, context)
        record_delegated_message(id, delegated_name, node, context)
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

    def promote_module_function(context, name, location)
      instance_id = "#{context.owner}##{name}"
      index = nodes.rindex { |candidate| candidate.id == instance_id }
      return unless index

      instance_node = nodes[index]
      nodes[index] = instance_node.with(visibility: :private)
      nodes << Node.new(
        id: "#{context.owner}.#{name}",
        kind: :singleton_method,
        file: context.relative_file,
        line: location.start_line,
        end_line: location.end_line,
        defined_via: :module_function,
        owner: context.owner,
        name: name,
        test: context.test,
        visibility: :public
      )
    end

    def callback_names(node)
      names = symbol_arguments(node)
      with = keyword_value(node, 'with')
      names << with if with.is_a?(String)
      names.uniq
    end

    def custom_validator_names(node)
      keyword_keys(node).reject { |name| RAILS_BUILTIN_VALIDATORS.include?(name) }.map do |name|
        name.split('_').map(&:capitalize).join
      end
    end

    def delegated_method_name(name, target, prefix)
      return name unless prefix

      prefix_name = prefix == true ? target.to_s.delete_prefix('@') : prefix.to_s
      "#{prefix_name}_#{name}"
    end

    def record_delegate_target(caller_id, target, node, context)
      record_reference_call(caller_id, target.to_s.delete_prefix('@'), node, context, receiver_kind: :self)
    end

    def record_delegated_message(caller_id, message, node, context)
      record_reference_call(caller_id, message, node, context, receiver_kind: :unknown)
    end

    def record_symbol_reference(node, context)
      return unless SYMBOL_REFERENCE_CALLS.include?(node.name)

      message = first_symbol_argument(node) || first_string_argument(node)
      return unless message

      receiver = classify_receiver(node.receiver, context)
      record_reference_call(
        context.current_caller_id,
        message,
        node,
        context,
        receiver_kind: receiver[:kind],
        receiver_name: receiver[:name],
        candidates: receiver[:candidates]
      )
    end

    def record_symbol_to_proc(node, context)
      block = node.block
      return unless block.is_a?(Prism::BlockArgumentNode)
      return unless block.expression.is_a?(Prism::SymbolNode)

      record_reference_call(
        context.current_caller_id,
        block.expression.unescaped.to_s,
        node,
        context,
        receiver_kind: :unknown
      )
    end

    def record_reference_call(caller_id, message, node, context, receiver_kind:, receiver_name: nil, candidates: [])
      call_sites << CallSite.new(
        caller_id: caller_id,
        message: message.to_s,
        receiver_kind: receiver_kind,
        receiver_name: receiver_name,
        file: context.relative_file,
        line: node.location.start_line,
        test: context.test,
        dynamic: false,
        metadata: { 'symbol_reference' => true, 'receiver_candidates' => Array(candidates) }
      )
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
      candidates << name
      candidates.uniq
    end
  end
end
