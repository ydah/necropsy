# frozen_string_literal: true

require 'prism'
require 'forwardable'
require_relative 'ast_scanner/definition_emitter'
require_relative 'ast_scanner/file_scanner'
require_relative 'ast_scanner/call_site_emitter'
require_relative 'ast_scanner/definition_creation'
require_relative 'ast_scanner/call_site_creation'
require_relative 'ast_scanner/traversal'
require_relative 'ast_scanner/value_definitions'
require_relative 'ast_scanner/method_definitions'
require_relative 'ast_scanner/dsl_macros'
require_relative 'ast_scanner/call_recording'
require_relative 'ast_scanner/references'
require_relative 'ast_scanner/ruby_semantics'

module Necropsy
  ScanResult = Data.define(
    :nodes,
    :call_sites,
    :instantiated_classes,
    :uncertainties,
    :class_infos,
    :entrypoint_hints,
    :file_statuses,
    :source_errors,
    :source_domains,
    :scope_diagnostics,
    :method_signatures,
    :semantic_blockers
  ) do
    def initialize(nodes:, call_sites:, instantiated_classes:, uncertainties:, class_infos:, entrypoint_hints:,
                   file_statuses: {}, source_errors: [], source_domains: {}, scope_diagnostics: {},
                   method_signatures: {}, semantic_blockers: [])
      super
    end
  end

  ScanState = Data.define(
    :nodes,
    :call_sites,
    :instantiated_classes,
    :uncertainties,
    :class_data,
    :entrypoint_hints,
    :file_statuses,
    :source_errors,
    :definition_ordinals,
    :call_site_ordinals,
    :module_function_sources,
    :deferred_module_functions,
    :method_signatures,
    :semantic_blockers,
    :constant_facts,
    :ambiguous_constant_facts,
    :source_domains,
    :scope_diagnostics,
    :factory_methods,
    :convention_rules
  )

  class AstScanner
    extend Forwardable

    CallTraversal = Data.define(:receiver, :arguments, :block)
    ATTR_MACROS = %i[attr_reader attr_writer attr_accessor].freeze
    DYNAMIC_SENDS = %i[send public_send __send__].freeze
    MODULE_RELATION_MACROS = %i[include prepend extend].freeze
    RAILS_CALLBACK_MACROS = %i[
      before_action after_action around_action
      before_validation after_validation before_save after_save around_save
      around_validation before_touch after_touch
      before_enqueue around_enqueue after_enqueue before_perform around_perform after_perform
      before_create after_create around_create before_update after_update around_update
      before_destroy after_destroy around_destroy after_commit after_rollback after_initialize after_find
      after_create_commit after_update_commit after_destroy_commit after_save_commit
      validate rescue_from helper_method
    ].freeze
    RAILS_GENERATED_METHOD_MACROS = %i[
      enum store store_accessor attribute class_attribute mattr_reader mattr_writer mattr_accessor
      cattr_reader cattr_writer cattr_accessor belongs_to has_one has_many scope
    ].freeze
    RAILS_RUNTIME_BLOCK_MACROS = %i[discard_on retry_on stream_for stream_from].freeze
    SIDEKIQ_RUNTIME_BLOCK_MACROS = %i[sidekiq_retries_exhausted sidekiq_retry_in].freeze
    VISIBILITY_MACROS = %i[public protected private public_class_method private_class_method].freeze
    SYMBOL_REFERENCE_CALLS = %i[method respond_to? try try!].freeze
    ANCESTRY_CONTROL_FLOW_TYPES = %i[
      and_node block_node case_match_node case_node else_node for_node if_node in_node lambda_node
      or_node rescue_modifier_node rescue_node until_node when_node while_node
    ].freeze
    RAILS_BUILTIN_VALIDATORS = %w[
      absence acceptance allow_blank allow_nil comparison confirmation exclusion format if inclusion length message numericality
      on presence strict uniqueness unless
    ].freeze

    Context = Struct.new(
      :namespace,
      :lexical_nesting,
      :owner,
      :current_caller_id,
      :current_method_name,
      :current_kind,
      :root_id,
      :file,
      :relative_file,
      :test,
      :singleton_scope,
      :visibility,
      :module_function,
      :static_ancestry,
      :flow_result,
      keyword_init: true
    )

    def initialize(project:, files:, source_domains: nil, scope_diagnostics: {})
      @project = project
      @files = files
      @state = ScanState.new(
        nodes: [],
        call_sites: [],
        instantiated_classes: Set.new,
        uncertainties: Hash.new { |hash, key| hash[key] = [] },
        class_data: {},
        entrypoint_hints: [],
        file_statuses: {},
        source_errors: [],
        definition_ordinals: Hash.new(0),
        call_site_ordinals: Hash.new(0),
        module_function_sources: {},
        deferred_module_functions: {},
        method_signatures: {},
        semantic_blockers: [],
        constant_facts: {},
        ambiguous_constant_facts: Set.new,
        source_domains: source_domains || files.to_h { |file| [project.relative_path(file), :analyze] },
        scope_diagnostics: scope_diagnostics,
        factory_methods: project.config.factory_methods.to_set(&:to_s),
        convention_rules: ConventionRules.new
      )
      @definition_emitter = DefinitionEmitter.new(state: @state)
      @call_site_emitter = CallSiteEmitter.new(state: @state)
      @ruby_semantics = RubySemantics.new(
        state: @state,
        record_semantic_blocker: method(:record_semantic_blocker)
      )
    end

    def scan
      ordered_files = files.sort_by { |file| project.relative_path(file) }
      collect_constant_facts(ordered_files)
      ordered_files.each { |file| scan_file(file) }
      resolve_deferred_module_function_sources
      copy_module_function_call_sites
      ScanResult.new(
        nodes: nodes,
        call_sites: call_sites,
        instantiated_classes: instantiated_classes,
        uncertainties: uncertainties,
        class_infos: class_infos,
        entrypoint_hints: entrypoint_hints.uniq,
        file_statuses: file_statuses,
        source_errors: source_errors,
        source_domains: source_domains,
        scope_diagnostics: scope_diagnostics,
        method_signatures: method_signatures,
        semantic_blockers: semantic_blockers.sort_by { |blocker| BoundedCanonicalizer.dump(blocker.to_h) }
      )
    end

    private

    def collect_constant_facts(files)
      files.each do |file|
        result = Prism.parse(File.read(file))
        static_constant_writes(result.value).each do |node, namespace|
          flow = FlowInterpreter.new(
            constant_resolver: ->(name) { name },
            constant_facts: constant_facts_for(Array(namespace).compact),
            allow_constant_writes: false
          ).analyze(node.value)
          fact = flow.return_fact
          next unless fact.exact

          register_constant_fact(qualify_constant(node.name.to_s, namespace), fact)
        end
      rescue SystemCallError, EncodingError
        next
      end
    end

    def flow_result_for(node, context)
      FlowInterpreter.new(
        constant_resolver: ->(constant) { resolve_candidate_group(constant_candidates(constant, context.lexical_nesting)) },
        constant_facts: constant_facts_for(context.lexical_nesting),
        allow_constant_writes: false
      ).analyze(node)
    end

    def scan_file(file)
      FileScanner.new(
        project: project,
        file: file,
        state: state,
        definition_emitter: definition_emitter,
        flow_result: method(:flow_result_for),
        visit: method(:visit),
        record_parse_errors: method(:record_parse_errors),
        record_source_failure: method(:record_source_failure)
      ).scan
    end

    def static_constant_writes(node, namespace = nil)
      case node
      when Prism::ProgramNode
        static_constant_writes(node.statements, namespace)
      when Prism::StatementsNode
        node.body.flat_map { |child| static_constant_writes(child, namespace) }
      when Prism::ClassNode, Prism::ModuleNode
        child_namespace = qualify_constant(constant_name(node.constant_path), namespace)
        static_constant_writes(node.body, child_namespace)
      when Prism::ConstantWriteNode
        [[node, namespace]]
      else
        []
      end
    end

    def register_constant_fact(name, fact)
      return if name.nil? || ambiguous_constant_facts.include?(name)

      current = constant_facts[name]
      if current && current.to_h != fact.to_h
        constant_facts.delete(name)
        ambiguous_constant_facts.add(name)
      else
        constant_facts[name] = fact
      end
    end

    def constant_facts_for(lexical_nesting)
      lexical_nesting = Array(lexical_nesting).compact
      constant_facts.each_with_object({}) do |(name, fact), result|
        next if ambiguous_constant_facts.include?(name)

        result[name] = fact
        next unless name.include?('::')

        namespace, local_name = name.rpartition('::').values_at(0, 2)
        visible = lexical_nesting.any? do |scope|
          scope == namespace || scope.start_with?("#{namespace}::")
        end
        result[local_name] ||= fact if visible
      end
    end

    def handled_call(receiver: true, arguments: true, block: false)
      CallTraversal.new(receiver: receiver, arguments: arguments, block: block)
    end

    attr_reader :project, :files, :state, :definition_emitter, :call_site_emitter, :ruby_semantics

    %i[
      classify_receiver first_symbol_argument first_string_argument literal_argument literal_name?
      symbol_arguments arguments keyword_value keyword_keys literal_value method_signature call_arguments
      incomplete_arguments constant_name qualify_constant record_class_info implicit_superclass_candidates
      class_record class_infos resolve_candidate_groups resolve_candidate_group constant_candidates inherited_namespaces
    ].each do |method_name|
      define_method(method_name) do |*args, **kwargs|
        ruby_semantics.public_send(method_name, *args, **kwargs)
      end
    end

    def_delegators :state, :nodes, :call_sites, :instantiated_classes, :uncertainties, :class_data,
                   :entrypoint_hints, :file_statuses, :source_errors, :definition_ordinals,
                   :module_function_sources, :deferred_module_functions, :call_site_ordinals,
                   :source_domains, :scope_diagnostics, :method_signatures, :semantic_blockers,
                   :constant_facts, :ambiguous_constant_facts, :factory_methods, :convention_rules
  end
end
