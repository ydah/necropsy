# frozen_string_literal: true

module Necropsy
  TYPE_FACT_TRUST_LEVELS = %i[authoritative hint conflicting].freeze

  TypeFact = Data.define(:subject, :types, :trust, :source, :complete) do
    def initialize(subject:, types:, source:, trust: :hint, complete: false)
      subject = subject.to_s
      raise ArgumentError, 'type fact subject must not be empty' if subject.empty?

      types = Array(types).map(&:to_s).reject(&:empty?).uniq.sort.freeze
      raise ArgumentError, 'type fact requires at least one type' if types.empty?

      trust = trust.to_sym
      raise ArgumentError, "invalid type fact trust: #{trust.inspect}" unless TYPE_FACT_TRUST_LEVELS.include?(trust)

      source = source.to_s
      raise ArgumentError, 'type fact source must not be empty' if source.empty?

      super(subject: subject.freeze, types: types, trust: trust, source: source.freeze, complete: complete == true)
    end

    def safe_for_resolution?
      trust == :authoritative && complete
    end

    def to_h
      {
        'subject' => subject,
        'types' => types,
        'trust' => trust.to_s,
        'source' => source,
        'complete' => complete
      }
    end
  end

  module TypeProvider
    module_function

    def profile
      AnalyzerProfile.new(
        name: 'none', kind: :type, soundness: :hint,
        description: 'No external type provider is enabled; core analysis remains independent.', version: '1',
        assumptions: ['type facts are optional', 'hints never refute a target']
      )
    end

    def facts(_project)
      []
    end
  end
end
