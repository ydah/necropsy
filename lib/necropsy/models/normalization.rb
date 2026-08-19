# frozen_string_literal: true

module Necropsy
  CONFIDENCE_LEVELS = {
    low: 0,
    medium: 1,
    high: 2,
    certain: 3
  }.freeze
  ACTIONABILITY_LEVELS = {
    diagnostic: 0,
    investigate: 1,
    review_candidate: 2,
    verified_candidate: 3
  }.freeze
  REACHABILITY_STATES = %i[
    observed_alive statically_reachable externally_reachable unreachable_under_model unknown
  ].freeze
  ANALYSIS_COMPLETENESS_STATES = %i[complete partial invalid].freeze
  ACTIONABILITY_STATES = ACTIONABILITY_LEVELS.keys.freeze

  UNKNOWN_SCOPE_KINDS = %i[definition symbol message owner namespace file global].freeze
  UNKNOWN_SCOPE_MATCHES = %i[exact glob].freeze
  RESOLUTION_STATUSES = %i[complete partial unknown].freeze
  EVIDENCE_GRADES = %i[exact conservative observed heuristic].freeze
  ANALYZER_KINDS = %i[static dynamic type].freeze
  ANALYZER_SOUNDNESS = %i[unsound conservative partial observational hint].freeze
  EVIDENCE_MAX_DETAILS_BYTES = 4_096
  EVIDENCE_MAX_METADATA_DEPTH = 32
  EVIDENCE_MAX_METADATA_ITEMS = 10_000
  EVIDENCE_MAX_METADATA_STRING_BYTES = 65_536
  EVIDENCE_MAX_METADATA_BYTES = 1_048_576
  PROFILE_MAX_DESCRIPTION_BYTES = 4_096
  PROFILE_MAX_VERSION_BYTES = 128
  PROFILE_MAX_ASSUMPTIONS = 64
  PROFILE_MAX_ASSUMPTION_BYTES = 512
  ROOT_DOMAINS = %i[runtime test external].freeze
  private_constant :UNKNOWN_SCOPE_KINDS, :UNKNOWN_SCOPE_MATCHES, :RESOLUTION_STATUSES, :EVIDENCE_GRADES,
                   :ANALYZER_KINDS, :ANALYZER_SOUNDNESS, :ROOT_DOMAINS
  private_constant :EVIDENCE_MAX_DETAILS_BYTES, :EVIDENCE_MAX_METADATA_DEPTH, :EVIDENCE_MAX_METADATA_ITEMS,
                   :EVIDENCE_MAX_METADATA_STRING_BYTES, :EVIDENCE_MAX_METADATA_BYTES,
                   :PROFILE_MAX_DESCRIPTION_BYTES, :PROFILE_MAX_VERSION_BYTES, :PROFILE_MAX_ASSUMPTIONS,
                   :PROFILE_MAX_ASSUMPTION_BYTES

  module ModelNormalization
    module_function

    def attributes(value, model_name)
      raise ArgumentError, "#{model_name} must be loaded from a Hash" unless value.is_a?(Hash)

      value.to_h { |key, item| [key.to_s, item] }
    end

    def identifier(value, field)
      normalized = value.to_s
      raise ArgumentError, "#{field} must not be empty" if normalized.empty?

      normalized.freeze
    end

    def string_list(values, field)
      list(values).map { |value| identifier(value, field) }.uniq.sort.freeze
    end

    def scope_value(value)
      normalized = if value.is_a?(Array)
                     string_list(value, 'scope_value')
                   else
                     identifier(value, 'scope_value')
                   end
      raise ArgumentError, 'scope_value must not be empty' if normalized.respond_to?(:empty?) && normalized.empty?

      normalized
    end

    def list(values)
      return [] if values.nil?

      values.is_a?(Array) ? values : [values]
    end

    def canonical(value)
      case value
      when nil
        'nil'
      when true, false, Numeric
        "#{value.class}:#{value}"
      when Symbol
        "symbol:#{canonical_string(value)}"
      when String
        "string:#{canonical_string(value)}"
      when Array
        "array:[#{value.map { |item| canonical(item) }.join(',')}]"
      when Hash
        pairs = value.map { |key, item| [canonical(key), canonical(item)] }.sort_by(&:first)
        "hash:{#{pairs.map { |key, item| "#{key}=#{item}" }.join(',')}}"
      else
        return canonical(value.to_h) if value.respond_to?(:to_h)

        "#{value.class}:#{canonical_string(value)}"
      end
    end

    def canonical_string(value)
      string = value.to_s
      "#{string.bytesize}:#{string}"
    end
  end
  private_constant :ModelNormalization
end
