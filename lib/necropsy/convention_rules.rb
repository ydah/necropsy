# frozen_string_literal: true

module Necropsy
  class ConventionRules
    Rule = Data.define(:id, :family, :method_names, :owner_patterns, :ancestor_patterns, :frameworks) do
      def initialize(id:, family:, methods: [], owner_patterns: [], ancestor_patterns: [], frameworks: [])
        id = id.to_s
        family = family.to_sym
        raise ArgumentError, 'rule id must not be empty' if id.empty?
        raise ArgumentError, 'rule family must not be empty' if family.to_s.empty?
        raise ArgumentError, 'rule methods must be bounded strings' unless Array(methods).all? do |name|
          name.is_a?(String) && !name.empty? && name.bytesize <= 128
        end
        raise ArgumentError, 'rule owner patterns must be bounded strings' unless Array(owner_patterns).all? do |pattern|
          pattern.is_a?(String) && !pattern.empty? && pattern.bytesize <= 256
        end
        raise ArgumentError, 'rule ancestor patterns must be bounded strings' unless Array(ancestor_patterns).all? do |pattern|
          pattern.is_a?(String) && !pattern.empty? && pattern.bytesize <= 256
        end
        raise ArgumentError, 'rule frameworks must be bounded strings' unless Array(frameworks).all? do |name|
          name.is_a?(String) && !name.empty? && name.bytesize <= 64
        end
        raise ArgumentError, 'rules may not be unscoped' if Array(owner_patterns).empty? && Array(ancestor_patterns).empty?

        super(
          id: id.freeze,
          family: family,
          method_names: Array(methods).map(&:to_s).uniq.sort.freeze,
          owner_patterns: Array(owner_patterns).map(&:to_s).uniq.sort.freeze,
          ancestor_patterns: Array(ancestor_patterns).map(&:to_s).uniq.sort.freeze,
          frameworks: Array(frameworks).map(&:to_s).uniq.sort.freeze
        )
      end
    end

    BUILT_IN = [
      Rule.new(
        id: 'rubocop.event_callback', family: :ancestor_scoped_hook,
        ancestor_patterns: ['RuboCop::Cop', 'RuboCop::Cop::Base'], frameworks: ['rubocop']
      ),
      Rule.new(
        id: 'rails.callback_symbol', family: :symbol_argument_method_reference,
        methods: %w[after_action after_save before_action before_save validate],
        owner_patterns: ['*Controller', '*Job', '*Mailer', '*Record', '*Validator'], frameworks: ['rails']
      ),
      Rule.new(
        id: 'rails.application_base', family: :ancestor_scoped_hook,
        methods: %w[after_action after_save before_action before_save validate],
        ancestor_patterns: %w[ApplicationController ApplicationJob ApplicationMailer ApplicationRecord],
        frameworks: ['rails']
      ),
      Rule.new(
        id: 'rails.action_cable', family: :framework_runtime_hook,
        methods: %w[receive subscribed unsubscribed], owner_patterns: ['*Channel'], frameworks: ['rails']
      ),
      Rule.new(
        id: 'rails.active_job', family: :framework_runtime_hook,
        methods: %w[deserialize perform serialize], owner_patterns: ['*Job'], ancestor_patterns: ['ApplicationJob'],
        frameworks: ['rails']
      ),
      Rule.new(
        id: 'sidekiq.worker', family: :framework_runtime_hook,
        methods: ['perform'], ancestor_patterns: %w[Sidekiq::Job Sidekiq::Worker], frameworks: ['sidekiq']
      ),
      Rule.new(
        id: 'graphql.runtime', family: :framework_runtime_hook,
        methods: %w[authorized? ready? resolve subscribed update],
        owner_patterns: %w[*Mutation *Resolver *Subscription *Type],
        ancestor_patterns: %w[GraphQL::Schema::Mutation GraphQL::Schema::Resolver GraphQL::Schema::Subscription],
        frameworks: ['graphql']
      ),
      Rule.new(
        id: 'active_model_serializers.public_surface', family: :declarative_public_surface,
        owner_patterns: ['*Serializer'], frameworks: ['active_model_serializers']
      ),
      Rule.new(
        id: 'blueprinter.public_surface', family: :declarative_public_surface,
        owner_patterns: ['*Blueprint'], frameworks: ['blueprinter']
      ),
      Rule.new(
        id: 'view_component.runtime', family: :framework_runtime_hook,
        methods: %w[before_render call render?], owner_patterns: ['*Component'], frameworks: ['view_component']
      )
    ].freeze

    MAX_RULES = 32

    def initialize(rules: BUILT_IN)
      @rules = Array(rules).freeze
      validate_rules!
    end

    def method_hit(owner:, method_name:, ancestors:, frameworks: [])
      candidate = @rules.find do |rule|
        next false unless rule.method_names.empty? || rule.method_names.include?(method_name.to_s)
        next false unless framework_enabled?(rule, frameworks)

        scoped_match?(rule, owner, ancestors)
      end
      hit(candidate, owner: owner, method_name: method_name) if candidate
    end

    private

    attr_reader :rules

    def validate_rules!
      raise ArgumentError, "too many convention rules (max #{MAX_RULES})" if rules.length > MAX_RULES

      ids = rules.map(&:id)
      raise ArgumentError, 'convention rule ids must be unique' unless ids.uniq == ids
    end

    def framework_enabled?(rule, frameworks)
      rule.frameworks.empty? || rule.frameworks.intersect?(Array(frameworks).map(&:to_s))
    end

    def scoped_match?(rule, owner, ancestors)
      owner = owner.to_s
      ancestors = Array(ancestors).map(&:to_s)
      owner_matches = rule.owner_patterns.any? { |pattern| File.fnmatch?(pattern, owner, File::FNM_EXTGLOB) }
      ancestor_matches = rule.ancestor_patterns.any? do |pattern|
        ancestors.any? { |candidate| candidate == pattern || candidate.start_with?("#{pattern}::") }
      end
      owner_matches || ancestor_matches
    end

    def hit(rule, owner:, method_name:)
      {
        'rule_id' => rule.id,
        'family' => rule.family.to_s,
        'owner' => owner.to_s,
        'method' => method_name.to_s,
        'reason' => "#{rule.id} matched #{owner}##{method_name}"
      }.freeze
    end
  end
end
