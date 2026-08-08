# frozen_string_literal: true

require 'rubygems'

module Necropsy
  module Bench
    class ReleaseAudit
      class ConfigValidator
        REQUIRED_CORPORA = %w[dynamic_evidence plain_ruby rails rubocop_1_75_0 self].freeze
        REQUIRED_ADVERSARIAL_SUITES = %w[ambiguity dynamic parse remote_input].freeze
        REQUIRED_REVIEW_POLICIES = %w[rails rubocop_1_75_0].freeze

        def initialize(config, strict_release: true)
          @config = config
          @strict_release = strict_release
        end

        def validate!
          raise Error, 'Release audit config must be a mapping' unless config.is_a?(Hash)
          raise Error, 'Release audit schema_version must be 1' unless config['schema_version'] == 1

          validate_nonempty_unique('corpora', config['corpora'])
          validate_suites
          validate_review_policies
          validate_precision_gate
          validate_strict_release if strict_release
          config
        end

        private

        attr_reader :config, :strict_release

        def validate_nonempty_unique(label, values)
          items = Array(values)
          raise Error, "Release audit #{label} must not be empty" if items.empty?
          return if items.uniq.length == items.length

          raise Error, "Release audit #{label} must not contain duplicates"
        end

        def validate_suites
          suites = config['adversarial_suites']
          raise Error, 'Release audit adversarial_suites must not be empty' unless suites.is_a?(Hash) && !suites.empty?

          suites.each do |name, definition|
            command = definition.is_a?(Hash) ? definition['command'] : nil
            next unless Array(command).empty?

            raise Error, "Adversarial suite #{name} must define a non-empty command"
          end
        end

        def validate_review_policies
          policies = config.dig('review', 'corpora')
          raise Error, 'Release audit review policies must not be empty' unless policies.is_a?(Hash) && !policies.empty?

          policies.each do |corpus, policy|
            strategy = policy['strategy']
            raise Error, "Invalid review strategy for #{corpus}" unless %w[all stratified].include?(strategy)
            next unless strategy == 'stratified'

            minimum = Integer(policy['minimum_per_stratum'], exception: false)
            raise Error, "Review sample size for #{corpus} must be positive" unless minimum&.positive?
          end
        end

        def validate_precision_gate
          required = Gem::Version.new(config.fetch('release', '0')) >= Gem::Version.new('0.4.0')
          policy = config['precision_gate']
          raise Error, 'Release audit 0.4+ requires precision_gate policy' if required && !policy.is_a?(Hash)
          return unless policy
          raise Error, 'Release audit precision_gate must be a mapping' unless policy.is_a?(Hash)

          threshold = Float(policy.fetch('minimum_precision', 0.85), exception: false)
          raise Error, 'Release audit minimum_precision must be between 0.0 and 1.0' unless
            threshold&.finite? && threshold.between?(0.0, 1.0)

          features = policy['default_features']
          raise Error, 'Release audit default_features must be a non-empty array' unless
            features.is_a?(Array) && !features.empty?
          return if features.all? { |feature| feature.is_a?(String) && !feature.empty? } && features.uniq == features

          raise Error, 'Release audit default_features must contain unique strings'
        rescue ArgumentError
          raise Error, "Invalid release version #{config['release'].inspect}"
        end

        def validate_strict_release
          baseline_ref = config.dig('baseline', 'git_ref').to_s
          raise Error, 'Release audit baseline must use a full Git SHA' unless baseline_ref.match?(/\A[0-9a-f]{40}\z/)

          validate_exact_set('corpora', config.fetch('corpora'), REQUIRED_CORPORA)
          validate_exact_set('adversarial suites', config.fetch('adversarial_suites').keys,
                             REQUIRED_ADVERSARIAL_SUITES)
          policies = config.dig('review', 'corpora')
          validate_exact_set('review policies', policies.keys, REQUIRED_REVIEW_POLICIES)
          raise Error, 'Rails release review must inspect all changes' unless policies.dig('rails', 'strategy') == 'all'
          return if policies.dig('rubocop_1_75_0', 'strategy') == 'stratified'

          raise Error, 'RuboCop release review must use stratified sampling'
        end

        def validate_exact_set(label, actual, expected)
          return if Array(actual).sort == expected.sort

          raise Error, "Release audit #{label} must be exactly #{expected.sort.inspect}"
        end
      end
    end
  end
end
