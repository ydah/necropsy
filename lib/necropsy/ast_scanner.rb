# frozen_string_literal: true

require 'prism'
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

  class AstScanner
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
      @source_domains = source_domains || files.to_h { |file| [project.relative_path(file), :analyze] }
      @scope_diagnostics = scope_diagnostics
      @nodes = []
      @call_sites = []
      @instantiated_classes = Set.new
      @uncertainties = Hash.new { |hash, key| hash[key] = [] }
      @class_data = {}
      @entrypoint_hints = []
      @file_statuses = {}
      @source_errors = []
      @definition_ordinals = Hash.new(0)
      @call_site_ordinals = Hash.new(0)
      @module_function_sources = {}
      @deferred_module_functions = {}
      @method_signatures = {}
      @semantic_blockers = []
      @factory_methods = project.config.factory_methods.to_set(&:to_s)
      @convention_rules = ConventionRules.new
    end

    def scan
      files.sort_by { |file| project.relative_path(file) }.each { |file| scan_file(file) }
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

    def handled_call(receiver: true, arguments: true, block: false)
      CallTraversal.new(receiver: receiver, arguments: arguments, block: block)
    end

    attr_reader :project, :files, :nodes, :call_sites, :instantiated_classes, :uncertainties, :class_data,
                :entrypoint_hints, :file_statuses, :source_errors, :definition_ordinals, :module_function_sources,
                :deferred_module_functions, :call_site_ordinals, :source_domains, :scope_diagnostics,
                :method_signatures, :semantic_blockers, :convention_rules
  end
end
