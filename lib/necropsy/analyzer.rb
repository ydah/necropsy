# frozen_string_literal: true

require 'digest'
require_relative 'bounded_canonicalizer'

module Necropsy
  module EvidenceIdentity
    module_function

    def generate(attributes)
      "evidence:v1:#{Digest::SHA256.hexdigest(BoundedCanonicalizer.dump(attributes))}"
    end

    # Analyzer-produced records are assembled from trusted scalar/model data.
    # Sorting ordinary Hash keys and using the JSON encoder avoids the
    # allocation-heavy type-tag/hex walk needed for untrusted legacy payloads.
    # EvidenceStore still canonicalizes the final payload and quarantines any
    # accidental fast-path collision.
    def generate_fast(attributes)
      "evidence:v1:#{Digest::SHA256.hexdigest(JSON.generate(fast_payload(attributes)))}"
    rescue JSON::GeneratorError, TypeError, SystemStackError
      generate(attributes)
    end

    def fast_payload(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, fast_payload(value.fetch(key))] }
      when Array
        value.map { |item| fast_payload(item) }
      when Symbol
        value.to_s
      else
        value.respond_to?(:to_h) ? fast_payload(value.to_h) : value
      end
    end
    private_class_method :fast_payload
  end
  private_constant :EvidenceIdentity

  module EvidenceCollection
    module_function

    def collect(*collections)
      records = collections.flatten.compact.map { |item| unwrap(item) }
      records.uniq { |record| identity(record) }
             .sort_by { |record| identity(record) }
             .freeze
    end

    def unwrap(item)
      item.respond_to?(:evidence) ? item.evidence : item
    end
    private_class_method :unwrap

    def identity(record)
      evidence_id = record.evidence_id if record.respond_to?(:evidence_id)
      return evidence_id if evidence_id

      payload = record.respond_to?(:to_h) ? record.to_h.except('evidence_id') : record
      EvidenceIdentity.generate(payload)
    end
    private_class_method :identity
  end
  private_constant :EvidenceCollection

  class Analyzer
    def analyze(_graph, _project)
      raise NotImplementedError, "#{self.class} must implement #analyze"
    end

    def profile
      raise NotImplementedError, "#{self.class} must implement #profile"
    end

    private

    def evidence(kind:, details:, analyzer: nil, weight: 1.0, metadata: {}, producer: nil, producer_version: nil,
                 grade: :heuristic, relation: nil, source: nil, assumptions: nil, scope: nil)
      analyzer_profile = profile
      analyzer ||= analyzer_profile.name
      producer ||= analyzer
      producer_version ||= analyzer_profile.version
      relation ||= kind
      assumptions = analyzer_profile.assumptions if assumptions.nil?
      producer_version ||= 'unversioned'
      source ||= { 'type' => 'analyzer', 'producer' => producer.to_s }
      scope ||= {}
      record = Evidence.new(
        analyzer: analyzer, kind: kind, weight: weight, details: details, metadata: metadata,
        producer: producer, producer_version: producer_version, grade: grade, relation: relation,
        source: source, assumptions: assumptions, scope: scope
      )
      evidence_id = EvidenceIdentity.generate_fast(record.to_h.except('evidence_id'))
      record.with(evidence_id: evidence_id)
    end

    def result_evidences(*collections)
      EvidenceCollection.collect(*collections)
    end

    def resolution_record(site, targets, evidences, status: nil, rejected_targets: [])
      analyzer_profile = profile
      target_ids = targets.map(&:graph_id).uniq.sort
      status ||= target_ids.empty? ? :unknown : :partial
      unknown_scope = residual_scope(site) unless status == :complete
      ResolutionRecord.new(
        resolution: Resolution.new(
          call_site_id: site.call_site_id,
          target_definition_ids: target_ids,
          status: status,
          unknown_scope: unknown_scope,
          rejected_targets: rejected_targets,
          evidence_ids: result_evidences(evidences).filter_map(&:evidence_id)
        ),
        producer: analyzer_profile.name,
        producer_version: analyzer_profile.version || 'unversioned',
        assumptions: analyzer_profile.assumptions
      )
    end

    def residual_scope(site)
      UnknownScope.new(scope_kind: :message, scope_value: site.message, match: :exact)
    end

    def call_site_evidence_source(site)
      { 'call_site_id' => site.call_site_id, 'file' => site.file, 'line' => site.line }
    end

    def call_site_evidence_scope(site)
      { 'call_site_id' => site.call_site_id, 'caller_definition_id' => site.caller_id }
    end
  end
end
