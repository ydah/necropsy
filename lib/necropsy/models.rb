# frozen_string_literal: true

require 'digest'

module Necropsy
  CONFIDENCE_LEVELS = {
    low: 0,
    medium: 1,
    high: 2,
    certain: 3
  }.freeze

  UNKNOWN_SCOPE_KINDS = %i[definition symbol message owner namespace file global].freeze
  UNKNOWN_SCOPE_MATCHES = %i[exact glob].freeze
  RESOLUTION_STATUSES = %i[complete partial unknown].freeze
  EVIDENCE_GRADES = %i[exact conservative observed heuristic].freeze
  ROOT_DOMAINS = %i[runtime test external].freeze
  private_constant :UNKNOWN_SCOPE_KINDS, :UNKNOWN_SCOPE_MATCHES, :RESOLUTION_STATUSES, :EVIDENCE_GRADES,
                   :ROOT_DOMAINS

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

  UnknownScope = Data.define(:scope_kind, :scope_value, :match) do
    def initialize(scope_kind:, scope_value:, match:)
      scope_kind = scope_kind.to_sym if scope_kind.respond_to?(:to_sym)
      match = match.to_sym if match.respond_to?(:to_sym)
      raise ArgumentError, "invalid unknown scope kind: #{scope_kind.inspect}" unless UNKNOWN_SCOPE_KINDS.include?(scope_kind)
      raise ArgumentError, "invalid unknown scope match: #{match.inspect}" unless UNKNOWN_SCOPE_MATCHES.include?(match)

      scope_value = ModelNormalization.scope_value(scope_value)
      super
    end

    def self.from_h(attributes)
      data = ModelNormalization.attributes(attributes, name)
      new(
        scope_kind: data.fetch('scope_kind'),
        scope_value: data.fetch('scope_value'),
        match: data.fetch('match')
      )
    end

    def to_h
      {
        'scope_kind' => scope_kind.to_s,
        'scope_value' => scope_value,
        'match' => match.to_s
      }
    end
  end

  RejectedTarget = Data.define(:definition_id, :reason, :evidence_ids) do
    def initialize(definition_id:, reason:, evidence_ids: [])
      definition_id = ModelNormalization.identifier(definition_id, 'definition_id')
      reason = ModelNormalization.identifier(reason, 'reason')
      evidence_ids = ModelNormalization.string_list(evidence_ids, 'evidence_id')
      super
    end

    def self.from_h(attributes)
      data = ModelNormalization.attributes(attributes, name)
      new(
        definition_id: data.fetch('definition_id'),
        reason: data.fetch('reason'),
        evidence_ids: data.fetch('evidence_ids', [])
      )
    end

    def to_h
      {
        'definition_id' => definition_id,
        'reason' => reason,
        'evidence_ids' => evidence_ids
      }
    end
  end

  Resolution = Data.define(
    :call_site_id,
    :target_definition_ids,
    :status,
    :unknown_scope,
    :rejected_targets,
    :evidence_ids
  ) do
    def initialize(call_site_id:, target_definition_ids:, status:, unknown_scope: nil, rejected_targets: [],
                   evidence_ids: [])
      call_site_id = ModelNormalization.identifier(call_site_id, 'call_site_id')
      target_definition_ids = ModelNormalization.string_list(target_definition_ids, 'target_definition_id')
      status = status.to_sym if status.respond_to?(:to_sym)
      raise ArgumentError, "invalid resolution status: #{status.inspect}" unless RESOLUTION_STATUSES.include?(status)

      unknown_scope = normalize_unknown_scope(unknown_scope)
      rejected_targets = normalize_rejected_targets(rejected_targets)
      evidence_ids = ModelNormalization.string_list(evidence_ids, 'evidence_id')
      validate_state!(status, target_definition_ids, unknown_scope)
      super
    end

    def self.from_h(attributes)
      data = ModelNormalization.attributes(attributes, name)
      new(
        call_site_id: data.fetch('call_site_id'),
        target_definition_ids: data.fetch('target_definition_ids', []),
        status: data.fetch('status'),
        unknown_scope: data['unknown_scope'],
        rejected_targets: data.fetch('rejected_targets', []),
        evidence_ids: data.fetch('evidence_ids', [])
      )
    end

    def to_h
      {
        'call_site_id' => call_site_id,
        'target_definition_ids' => target_definition_ids,
        'status' => status.to_s,
        'unknown_scope' => unknown_scope&.to_h,
        'rejected_targets' => rejected_targets.map(&:to_h),
        'evidence_ids' => evidence_ids
      }
    end

    private

    def normalize_unknown_scope(value)
      return if value.nil?
      return value if value.is_a?(UnknownScope)

      UnknownScope.from_h(value)
    rescue NoMethodError
      raise ArgumentError, 'unknown_scope must be an UnknownScope or Hash'
    end

    def normalize_rejected_targets(values)
      ModelNormalization.list(values).map do |value|
        value.is_a?(RejectedTarget) ? value : RejectedTarget.from_h(value)
      end.uniq.sort_by do |target|
        [target.definition_id, target.reason, target.evidence_ids]
      end.freeze
    rescue NoMethodError
      raise ArgumentError, 'rejected_targets must contain RejectedTarget values or Hashes'
    end

    def validate_state!(resolution_status, targets, scope)
      if resolution_status == :complete
        raise ArgumentError, 'complete resolution must not have an unknown scope' if scope

        return
      end

      raise ArgumentError, "#{resolution_status} resolution requires an unknown scope" unless scope

      if resolution_status == :partial
        raise ArgumentError, 'partial resolution requires at least one target' if targets.empty?
      elsif targets.any?
        raise ArgumentError, 'unknown resolution must not have targets'
      end
    end
  end

  ResolutionRecord = Data.define(:resolution, :producer, :producer_version, :assumptions) do
    def initialize(resolution:, producer:, producer_version: nil, assumptions: [])
      resolution = normalize_resolution(resolution)
      producer = ModelNormalization.identifier(producer, 'producer')
      producer_version = ModelNormalization.identifier(producer_version, 'producer_version') if producer_version
      assumptions = ModelNormalization.string_list(assumptions, 'assumption')
      super
    end

    def self.from_h(attributes)
      data = ModelNormalization.attributes(attributes, name)
      new(
        resolution: data.fetch('resolution'),
        producer: data.fetch('producer'),
        producer_version: data['producer_version'],
        assumptions: data.fetch('assumptions', [])
      )
    end

    def identity_key
      [resolution.call_site_id, producer, producer_version, assumptions].freeze
    end

    def to_h
      {
        'resolution' => resolution.to_h,
        'producer' => producer,
        'producer_version' => producer_version,
        'assumptions' => assumptions
      }
    end

    private

    def normalize_resolution(value)
      return value if value.is_a?(Resolution)

      Resolution.from_h(value)
    rescue NoMethodError
      raise ArgumentError, 'resolution must be a Resolution or Hash'
    end
  end

  Node = Data.define(
    :id,
    :symbol_id,
    :definition_id,
    :body_digest,
    :ordinal,
    :kind,
    :file,
    :line,
    :end_line,
    :defined_via,
    :owner,
    :name,
    :test,
    :visibility
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 10 && attributes.empty?

        id, kind, file, line, end_line, defined_via, owner, name, test, visibility = values
        data_new(
          id: id, kind: kind, file: file, line: line, end_line: end_line, defined_via: defined_via,
          owner: owner, name: name, test: test, visibility: visibility
        )
      end

      private :data_new, :compatible_new
    end

    def initialize(id:, kind:, file:, line:, end_line:, defined_via:, owner:, name:, test:, visibility:,
                   symbol_id: id, definition_id: id, body_digest: nil, ordinal: 0)
      super
    end

    def method?
      kind != :block_entry
    end

    def graph_id
      definition_id
    end

    def fingerprint(classification)
      Digest::SHA256.hexdigest("#{classification}:#{symbol_id}")
    end

    alias_method :logical_fingerprint, :fingerprint

    def physical_fingerprint(classification)
      Digest::SHA256.hexdigest("#{classification}:#{definition_id}")
    end

    def to_h
      {
        'id' => id,
        'symbol_id' => symbol_id,
        'definition_id' => definition_id,
        'body_digest' => body_digest,
        'ordinal' => ordinal,
        'kind' => kind.to_s,
        'file' => file,
        'line' => line,
        'end_line' => end_line,
        'defined_via' => defined_via.to_s,
        'owner' => owner,
        'name' => name,
        'test' => test,
        'visibility' => visibility.to_s
      }
    end
  end

  MethodLookup = Data.define(
    :targets,
    :status,
    :rejected_targets,
    :lookup_chain,
    :reason
  ) do
    def initialize(targets:, status:, rejected_targets: [], lookup_chain: [], reason: nil)
      status = status.to_sym
      raise ArgumentError, "invalid method lookup status: #{status.inspect}" unless RESOLUTION_STATUSES.include?(status)

      targets = Array(targets).uniq(&:graph_id).sort_by(&:graph_id).freeze
      rejected_targets = Array(rejected_targets).uniq.sort_by do |target|
        [target.definition_id, target.reason, target.evidence_ids]
      end.freeze
      lookup_chain = Array(lookup_chain).map(&:to_s).freeze
      super
    end

    def complete?
      status == :complete
    end

    def partial?
      status == :partial
    end

    def unknown?
      status == :unknown
    end

    def to_h
      {
        'target_definition_ids' => targets.map(&:graph_id),
        'status' => status.to_s,
        'rejected_targets' => rejected_targets.map(&:to_h),
        'lookup_chain' => lookup_chain,
        'reason' => reason
      }
    end
  end

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

    def provenance_present?(producer, producer_version, relation, source, assumptions, scope)
      [producer, producer_version, relation, source, scope].any? { |value| !value.nil? } || assumptions.any?
    end
  end

  Edge = Data.define(:caller_id, :callee_id, :evidences) do
    def to_h
      {
        'caller_id' => caller_id,
        'callee_id' => callee_id,
        'evidence_ids' => evidences.filter_map(&:evidence_id).sort,
        'evidences' => evidences.map(&:to_h)
      }
    end
  end

  EdgeRelation = Data.define(:caller_id, :callee_id, :evidence_ids, :projection) do
    def to_h
      {
        'caller_id' => caller_id,
        'callee_id' => callee_id,
        'evidence_ids' => evidence_ids,
        'projection' => projection.to_s
      }
    end
  end

  Root = Data.define(:definition_id, :domain, :reason, :evidence) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        return data_new(node_id: values[0], reason: values[1]) if values.length == 2 && attributes.empty?

        data_new(*values, **attributes)
      end
      alias_method :[], :new

      private :data_new
    end

    def initialize(reason:, definition_id: nil, node_id: nil, domain: nil, evidence: nil)
      definition_id ||= node_id
      definition_id = ModelNormalization.identifier(definition_id, 'definition_id')
      reason = ModelNormalization.identifier(reason, 'reason').to_sym
      domain ||= reason == :test_suite ? :test : :runtime
      domain = domain.to_sym if domain.respond_to?(:to_sym)
      raise ArgumentError, "invalid root domain: #{domain.inspect}" unless ROOT_DOMAINS.include?(domain)

      evidence ||= { 'type' => 'entry_point', 'reason' => reason.to_s }
      evidence = evidence.to_h if evidence.respond_to?(:to_h)
      raise ArgumentError, 'root evidence must be a Hash' unless evidence.is_a?(Hash)

      super(definition_id: definition_id, domain: domain, reason: reason, evidence: evidence.freeze)
    end

    alias_method :node_id, :definition_id

    def test?
      domain == :test
    end

    def runtime?
      domain == :runtime
    end

    def external?
      domain == :external
    end

    def to_h
      {
        'node_id' => node_id,
        'definition_id' => definition_id,
        'domain' => domain.to_s,
        'reason' => reason.to_s,
        'evidence' => evidence
      }
    end
  end
  EntryPoint = Root

  ClassInfo = Data.define(
    :id,
    :kind,
    :file,
    :line,
    :superclass,
    :superclass_candidates,
    :includes,
    :prepends,
    :extends,
    :singleton_includes,
    :singleton_prepends,
    :dynamic
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 10 && attributes.empty?

        id, kind, file, line, superclass, superclass_candidates, includes, prepends, extends, dynamic = values
        data_new(
          id: id,
          kind: kind,
          file: file,
          line: line,
          superclass: superclass,
          superclass_candidates: superclass_candidates,
          includes: includes,
          prepends: prepends,
          extends: extends,
          dynamic: dynamic
        )
      end
      alias_method :[], :new

      private :data_new
    end

    def initialize(id:, kind:, file:, line:, superclass:, superclass_candidates:, includes:, prepends:, extends:,
                   dynamic:, singleton_includes: [], singleton_prepends: [])
      singleton_includes = extends if singleton_includes.empty? && !extends.empty?
      super
    end

    def to_h
      {
        'id' => id,
        'kind' => kind.to_s,
        'file' => file,
        'line' => line,
        'superclass' => superclass,
        'superclass_candidates' => superclass_candidates,
        'includes' => includes,
        'prepends' => prepends,
        'extends' => extends,
        'singleton_includes' => singleton_includes,
        'singleton_prepends' => singleton_prepends,
        'dynamic' => dynamic
      }
    end
  end

  CallSite = Data.define(
    :call_site_id,
    :caller_id,
    :message,
    :receiver_kind,
    :receiver_name,
    :file,
    :line,
    :test,
    :dynamic,
    :metadata
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 9 && attributes.empty?

        caller_id, message, receiver_kind, receiver_name, file, line, test, dynamic, metadata = values
        data_new(
          caller_id: caller_id, message: message, receiver_kind: receiver_kind, receiver_name: receiver_name,
          file: file, line: line, test: test, dynamic: dynamic, metadata: metadata
        )
      end

      private :data_new, :compatible_new
    end

    def initialize(caller_id:, message:, receiver_kind:, receiver_name:, file:, line:, test:, dynamic:, metadata:,
                   call_site_id: nil)
      call_site_id ||= CallSiteIdentity.legacy_id(
        caller_definition_id: caller_id,
        message: message,
        receiver_kind: receiver_kind,
        receiver_name: receiver_name,
        file: file,
        line: line,
        test: test,
        dynamic: dynamic,
        metadata: metadata
      )
      super
    end

    alias_method :caller_definition_id, :caller_id

    def to_h
      {
        'call_site_id' => call_site_id,
        'caller_id' => caller_id,
        'caller_definition_id' => caller_definition_id,
        'message' => message,
        'receiver_kind' => receiver_kind.to_s,
        'receiver_name' => receiver_name,
        'file' => file,
        'line' => line,
        'test' => test,
        'dynamic' => dynamic,
        'metadata' => metadata
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
      version = ModelNormalization.identifier(version, 'version') if version
      assumptions = ModelNormalization.string_list(assumptions, 'assumption')
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
    :evidences
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless attributes.empty? && [4, 5].include?(values.length)

        edge_evidences, alive_evidences, uncertainties, observation, blockers = values
        blockers = [] if values.length == 4
        data_new(edge_evidences: edge_evidences, alive_evidences: alive_evidences, uncertainties: uncertainties, observation: observation,
                 blockers: blockers)
      end

      private :data_new, :compatible_new
    end

    def initialize(edge_evidences:, alive_evidences:, uncertainties:, observation:, blockers: [], resolutions: nil,
                   evidences: [])
      resolutions = normalize_resolutions(resolutions) unless resolutions.nil?
      super
    end

    def self.empty
      new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [],
        resolutions: [], evidences: []
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

  Finding = Data.define(:node, :classification, :confidence, :score, :score_components, :reasons, :evidences, :blockers) do
    def initialize(node:, classification:, confidence:, score:, score_components:, reasons:, evidences:, blockers: [])
      super
    end

    def at_least?(level)
      CONFIDENCE_LEVELS.fetch(confidence) >= CONFIDENCE_LEVELS.fetch(level)
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
        'score_components' => score_components.map(&:to_h),
        'node' => node.to_h,
        'reasons' => reasons,
        'evidences' => evidences.map(&:to_h),
        'blockers' => blockers.map(&:to_h)
      }
    end
  end
end
