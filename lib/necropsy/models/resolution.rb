# frozen_string_literal: true

module Necropsy
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
end
