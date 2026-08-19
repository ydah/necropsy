# frozen_string_literal: true

module Necropsy
  Evidence = Data.define(
    :analyzer,
    :kind,
    :weight,
    :details,
    :metadata,
    :evidence_id,
    :producer,
    :producer_version,
    :grade,
    :relation,
    :source,
    :assumptions,
    :scope
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 5 && attributes.empty?

        analyzer, kind, weight, details, metadata = values
        data_new(analyzer: analyzer, kind: kind, weight: weight, details: details, metadata: metadata)
      end

      private :data_new, :compatible_new
    end

    def initialize(analyzer:, kind:, weight:, details:, metadata:, evidence_id: nil, producer: nil,
                   producer_version: nil, grade: nil, relation: nil, source: nil, assumptions: [], scope: nil)
      raise ArgumentError, 'evidence analyzer must not be empty' if analyzer.to_s.empty?
      raise ArgumentError, 'evidence kind must not be empty' if kind.to_s.empty?

      weight = Float(weight)
      raise ArgumentError, 'evidence weight must be finite' unless weight.finite?

      valid_details = details.is_a?(String) && details.bytesize <= EVIDENCE_MAX_DETAILS_BYTES
      raise ArgumentError, 'evidence details must be a bounded string' unless valid_details
      raise ArgumentError, 'evidence metadata must be a mapping' unless metadata.is_a?(Hash)

      grade = grade.to_sym if grade.respond_to?(:to_sym)
      raise ArgumentError, "invalid evidence grade: #{grade.inspect}" unless grade.nil? || EVIDENCE_GRADES.include?(grade)

      evidence_id = ModelNormalization.identifier(evidence_id, 'evidence_id') unless evidence_id.nil?
      assumptions = ModelNormalization.string_list(assumptions, 'assumption')
      if grade.nil? && provenance_present?(producer, producer_version, relation, source, assumptions, scope)
        raise ArgumentError, 'evidence grade may be nil only for legacy evidence'
      end
      if grade && [producer, producer_version, relation, source, scope].any?(&:nil?)
        raise ArgumentError, 'graded evidence requires producer, producer_version, relation, source, and scope'
      end

      validate_bounded_payload!(metadata: metadata, source: source, scope: scope)

      super
    end

    def to_h
      {
        'analyzer' => analyzer.to_s,
        'kind' => kind.to_s,
        'weight' => weight,
        'details' => details,
        'metadata' => metadata,
        'evidence_id' => evidence_id,
        'producer' => producer&.to_s,
        'producer_version' => producer_version&.to_s,
        'grade' => grade&.to_s,
        'relation' => relation&.to_s,
        'source' => source.respond_to?(:to_h) ? source.to_h : source,
        'assumptions' => assumptions,
        'scope' => scope.respond_to?(:to_h) ? scope.to_h : scope
      }
    end

    private

    def validate_bounded_payload!(value)
      BoundedCanonicalizer.dump(
        value,
        max_depth: EVIDENCE_MAX_METADATA_DEPTH,
        max_items: EVIDENCE_MAX_METADATA_ITEMS,
        max_string_bytes: EVIDENCE_MAX_METADATA_STRING_BYTES,
        max_total_bytes: EVIDENCE_MAX_METADATA_BYTES
      )
    end

    def provenance_present?(producer, producer_version, relation, source, assumptions, scope)
      [producer, producer_version, relation, source, scope].any? { |value| !value.nil? } || assumptions.any?
    end
  end

  VALUE_FACT_KINDS = %i[
    class_object instance_types symbol_set string_set integer_set callable_set container nil boolean unknown
  ].freeze

  ValueFact = Data.define(:kind, :values, :exact, :nilable, :origin, :summary) do
    def initialize(kind:, values: [], exact: true, nilable: false, origin: nil, summary: nil)
      kind = kind.to_sym
      raise ArgumentError, "invalid value fact kind: #{kind.inspect}" unless VALUE_FACT_KINDS.include?(kind)

      values = Array(values).map(&:to_s).uniq.sort.freeze
      exact = (exact == true)
      nilable = (nilable == true)
      origin = origin&.to_s
      super
    end

    def self.instance_types(types, origin: :direct_constructor, nilable: false)
      new(kind: :instance_types, values: types, exact: true, nilable: nilable, origin: origin)
    end

    def self.unknown(origin = :unsupported)
      new(kind: :unknown, exact: false, origin: origin)
    end

    def self.from_h(attributes)
      data = attributes.transform_keys(&:to_s)
      new(
        kind: data.fetch('kind'),
        values: data.fetch('values', []),
        exact: data.fetch('exact', false),
        nilable: data.fetch('nilable', false),
        origin: data['origin'],
        summary: data['summary']
      )
    end

    def exact_instance_types?
      kind == :instance_types && exact && !values.empty?
    end

    def to_h
      {
        'kind' => kind.to_s,
        'values' => values,
        'exact' => exact,
        'nilable' => nilable,
        'origin' => origin,
        'summary' => summary
      }
    end
  end

  FlowResult = Data.define(:receiver_facts, :value_facts, :return_fact, :issues, :steps, :constant_facts) do
    def initialize(receiver_facts: {}, value_facts: {}, return_fact: ValueFact.unknown(:no_direct_return), issues: [], steps: 0,
                   constant_facts: {})
      receiver_facts = receiver_facts.dup.compare_by_identity.freeze
      value_facts = value_facts.dup.compare_by_identity.freeze
      issues = Array(issues).map(&:to_s).uniq.sort.freeze
      steps = Integer(steps)
      constant_facts = constant_facts.transform_keys(&:to_s).freeze
      super
    end

    def fact_for(node)
      value_facts[node] || receiver_facts[node]
    end

    def to_h
      {
        'receiver_facts' => receiver_facts.values.map(&:to_h),
        'value_fact_count' => value_facts.length,
        'return_fact' => return_fact.to_h,
        'issues' => issues,
        'steps' => steps,
        'constant_fact_count' => constant_facts.length
      }
    end
  end

  AnalyzerProfile = Data.define(:name, :kind, :soundness, :description, :version, :assumptions) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 4 && attributes.empty?

        name, kind, soundness, description = values
        data_new(name: name, kind: kind, soundness: soundness, description: description)
      end

      private :data_new, :compatible_new
    end

    def initialize(name:, kind:, soundness:, description:, version: nil, assumptions: [])
      ModelNormalization.identifier(name, 'analyzer profile name')
      kind = kind.to_sym if kind.respond_to?(:to_sym)
      soundness = soundness.to_sym if soundness.respond_to?(:to_sym)
      raise ArgumentError, "invalid analyzer kind: #{kind.inspect}" unless ANALYZER_KINDS.include?(kind)
      raise ArgumentError, "invalid analyzer soundness: #{soundness.inspect}" unless ANALYZER_SOUNDNESS.include?(soundness)
      unless description.is_a?(String) && !description.empty? && description.bytesize <= PROFILE_MAX_DESCRIPTION_BYTES
        raise ArgumentError, 'analyzer description must be a bounded non-empty string'
      end

      version = ModelNormalization.identifier(version, 'version') if version
      raise ArgumentError, 'analyzer version is too long' if version&.bytesize.to_i > PROFILE_MAX_VERSION_BYTES

      assumptions = ModelNormalization.string_list(assumptions, 'assumption')
      if assumptions.length > PROFILE_MAX_ASSUMPTIONS ||
         assumptions.any? { |assumption| assumption.bytesize > PROFILE_MAX_ASSUMPTION_BYTES }
        raise ArgumentError, 'analyzer assumptions must be bounded'
      end

      super
    end

    def to_h
      {
        'name' => name.to_s,
        'kind' => kind.to_s,
        'soundness' => soundness.to_s,
        'description' => description,
        'version' => version,
        'assumptions' => assumptions
      }
    end
  end

  EdgeEvidence = Data.define(:caller_id, :callee_id, :evidence)
  AliveEvidence = Data.define(:node_id, :evidence)

  SourceError = Data.define(:file, :line, :message, :type) do
    def to_h
      {
        'file' => file,
        'line' => line,
        'message' => message,
        'type' => type.to_s
      }
    end
  end

  AnalysisHealth = Data.define(:status, :reasons) do
    def self.from_reasons(reasons)
      normalized = Array(reasons).map { |reason| normalize_reason(reason) }
      status = normalized.any? { |reason| reason.fetch('severity') == 'invalid' } ? :invalid : :degraded
      status = :complete if normalized.empty?
      new(status: status || :complete, reasons: normalized)
    end

    def self.complete
      new(status: :complete, reasons: [])
    end

    def self.normalize_reason(reason)
      normalized = reason.to_h.transform_keys(&:to_s)
      severity = normalized.fetch('severity').to_sym
      raise ArgumentError, "invalid analysis health severity: #{severity}" unless %i[degraded invalid].include?(severity)
      raise ArgumentError, 'analysis health reason requires a code' if normalized.fetch('code', '').to_s.empty?

      normalized.merge('severity' => severity.to_s)
    end
    private_class_method :normalize_reason

    def initialize(status:, reasons: [])
      normalized_status = status.to_sym
      raise ArgumentError, "invalid analysis health status: #{status}" unless %i[complete degraded invalid].include?(normalized_status)

      super(status: normalized_status, reasons: reasons.freeze)
    end

    def complete?
      status == :complete
    end

    def to_h
      { 'status' => status.to_s, 'reasons' => reasons }
    end
  end

  Blocker = Data.define(:kind, :scope_kind, :scope_value, :source, :reason, :suggested_action, :metadata) do
    def initialize(kind:, scope_kind:, scope_value:, source:, reason:, suggested_action: :review, metadata: {})
      super
    end

    def message
      metadata['message'] || metadata[:message] || (scope_value if %i[message symbol].include?(scope_kind.to_sym))
    end

    def caller_domain
      (metadata['caller_domain'] || metadata[:caller_domain] || :runtime).to_sym
    end

    def to_h
      {
        'kind' => kind.to_s,
        'scope_kind' => scope_kind.to_s,
        'scope_value' => scope_value,
        'source' => source.respond_to?(:to_h) ? source.to_h : source.to_s,
        'reason' => reason,
        'suggested_action' => suggested_action.to_s,
        'metadata' => metadata
      }
    end
  end

  ScoreComponent = Data.define(:name, :value, :details) do
    def to_h
      { 'name' => name, 'value' => value, 'details' => details }
    end
  end

  AnalyzerResult = Data.define(
    :edge_evidences,
    :alive_evidences,
    :uncertainties,
    :observation,
    :blockers,
    :resolutions,
    :evidences,
    :derived_call_sites
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, []) if attributes.empty? && values.length == 7

        return data_new(*values, **attributes) unless attributes.empty? && [4, 5].include?(values.length)

        edge_evidences, alive_evidences, uncertainties, observation, blockers = values
        blockers = [] if values.length == 4
        data_new(edge_evidences: edge_evidences, alive_evidences: alive_evidences, uncertainties: uncertainties, observation: observation,
                 blockers: blockers)
      end

      private :data_new, :compatible_new
    end

    def initialize(edge_evidences:, alive_evidences:, uncertainties:, observation:, blockers: [], resolutions: nil,
                   evidences: [], derived_call_sites: [])
      resolutions = normalize_resolutions(resolutions) unless resolutions.nil?
      super
    end

    def self.empty
      new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [],
        resolutions: [], evidences: [], derived_call_sites: []
      )
    end

    private

    def normalize_resolutions(values)
      ModelNormalization.list(values).map do |value|
        normalize_resolution_record(value)
      end.sort_by { |record| ModelNormalization.canonical(record.to_h) }.freeze
    end

    def normalize_resolution_record(value)
      return value if value.is_a?(ResolutionRecord)
      return legacy_resolution_record(value) if value.is_a?(Resolution)

      data = ModelNormalization.attributes(value, 'AnalyzerResult resolution')
      return ResolutionRecord.from_h(data) if data.key?('resolution')

      legacy_resolution_record(Resolution.from_h(data))
    end

    def legacy_resolution_record(resolution)
      ResolutionRecord.new(resolution: resolution, producer: 'legacy')
    end
  end

  Finding = Data.define(
    :node, :classification, :confidence, :score, :score_components, :reasons, :evidences, :blockers,
    :reachability_state, :analysis_completeness, :actionability
  ) do
    def initialize(node:, classification:, confidence:, score:, score_components:, reasons:, evidences:, blockers: [],
                   reachability_state: nil, analysis_completeness: nil, actionability: nil)
      classification = classification.to_sym
      blockers = Array(blockers)
      reachability_state ||= default_reachability_state(classification)
      analysis_completeness ||= blockers.empty? ? :complete : :partial
      actionability ||= default_actionability(classification, blockers, analysis_completeness)
      validate_state!(reachability_state, analysis_completeness, actionability, blockers)
      reachability_state = reachability_state.to_sym
      analysis_completeness = analysis_completeness.to_sym
      actionability = actionability.to_sym
      super
    end

    def at_least?(level)
      CONFIDENCE_LEVELS.fetch(confidence) >= CONFIDENCE_LEVELS.fetch(level)
    end

    def actionability_at_least?(level)
      ACTIONABILITY_LEVELS.fetch(actionability) >= ACTIONABILITY_LEVELS.fetch(level)
    end

    def actionable?
      actionability_at_least?(:review_candidate)
    end

    def with(**changes)
      attributes = {
        node: node,
        classification: classification,
        confidence: confidence,
        score: score,
        score_components: score_components,
        reasons: reasons,
        evidences: evidences,
        blockers: blockers,
        reachability_state: reachability_state,
        analysis_completeness: analysis_completeness,
        actionability: actionability
      }.merge(changes)
      if changes.key?(:classification) || changes.key?(:blockers)
        attributes.delete(:reachability_state) unless changes.key?(:reachability_state)
        attributes.delete(:analysis_completeness) unless changes.key?(:analysis_completeness)
        attributes.delete(:actionability) unless changes.key?(:actionability)
      end
      self.class.new(**attributes)
    end

    def fingerprint
      node.fingerprint(classification)
    end

    alias_method :logical_fingerprint, :fingerprint

    def physical_fingerprint
      node.physical_fingerprint(classification)
    end

    def to_h
      {
        'fingerprint' => fingerprint,
        'logical_fingerprint' => logical_fingerprint,
        'physical_fingerprint' => physical_fingerprint,
        'classification' => classification.to_s,
        'confidence' => confidence.to_s,
        'score' => score,
        'priority_score' => score,
        'score_components' => score_components.map(&:to_h),
        'node' => node.to_h,
        'reasons' => reasons,
        'evidences' => evidences.map(&:to_h),
        'blockers' => blockers.map(&:to_h),
        'reachability_state' => reachability_state.to_s,
        'analysis_completeness' => analysis_completeness.to_s,
        'actionability' => actionability.to_s
      }
    end

    private

    def default_reachability_state(classification)
      return :unreachable_under_model if %i[unreachable unused].include?(classification)
      return :statically_reachable if classification == :test_only_reachable

      :unknown
    end

    def default_actionability(classification, matching_blockers, completeness)
      return :diagnostic unless matching_blockers.empty? && completeness == :complete
      return :review_candidate if %i[unreachable unused].include?(classification)

      :diagnostic
    end

    def validate_state!(reachability, completeness, candidate_actionability, matching_blockers)
      reachability = reachability.to_sym
      completeness = completeness.to_sym
      candidate_actionability = candidate_actionability.to_sym
      raise ArgumentError, "invalid finding reachability state: #{reachability}" unless
        REACHABILITY_STATES.include?(reachability)
      raise ArgumentError, "invalid finding analysis completeness: #{completeness}" unless
        ANALYSIS_COMPLETENESS_STATES.include?(completeness)
      raise ArgumentError, "invalid finding actionability: #{candidate_actionability}" unless
        ACTIONABILITY_STATES.include?(candidate_actionability)
      return unless ACTIONABILITY_LEVELS.fetch(candidate_actionability) >= ACTIONABILITY_LEVELS.fetch(:review_candidate)

      raise ArgumentError, 'incomplete findings cannot be actionable' unless completeness == :complete
      raise ArgumentError, 'blocked findings cannot be actionable' unless matching_blockers.empty?
    end
  end
end
