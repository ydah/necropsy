# frozen_string_literal: true

require 'prism'
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
    :source_errors
  ) do
    def initialize(nodes:, call_sites:, instantiated_classes:, uncertainties:, class_infos:, entrypoint_hints:,
                   file_statuses: {}, source_errors: [])
      super
    end
  end

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
      @file_statuses = {}
      @source_errors = []
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
        entrypoint_hints: entrypoint_hints.uniq,
        file_statuses: file_statuses,
        source_errors: source_errors
      )
    end

    private

    attr_reader :project, :files, :nodes, :call_sites, :instantiated_classes, :uncertainties, :class_data,
                :entrypoint_hints, :file_statuses, :source_errors
  end
end
