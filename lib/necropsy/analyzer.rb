# frozen_string_literal: true

require 'digest'

module Necropsy
  module EvidenceIdentity
    module_function

    def generate(attributes)
      "evidence:v1:#{Digest::SHA256.hexdigest(canonical(attributes))}"
    end

    def canonical(value)
      case value
      when nil
        'nil'
      when true, false, Numeric
        "#{value.class}:#{value}"
      when Symbol
        "symbol:#{canonical_string(value.to_s)}"
      when String
        "string:#{canonical_string(value)}"
      when Array
        "array:[#{value.map { |item| canonical(item) }.join(',')}]"
      when Hash
        pairs = value.map { |key, item| [canonical(key), canonical(item)] }.sort_by(&:first)
        "hash:{#{pairs.map { |key, item| "#{key}=#{item}" }.join(',')}}"
      else
        return canonical(value.to_h) if value.respond_to?(:to_h)

        "#{value.class}:#{canonical_string(value.to_s)}"
      end
    end

    def canonical_string(value)
      "#{value.bytesize}:#{value}"
    end
    private_class_method :canonical, :canonical_string
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
      record = Evidence.new(
        analyzer: analyzer, kind: kind, weight: weight, details: details, metadata: metadata,
        producer: producer, producer_version: producer_version, grade: grade, relation: relation,
        source: source, assumptions: assumptions, scope: scope
      )
      evidence_id = EvidenceIdentity.generate(record.to_h.except('evidence_id'))
      record.with(evidence_id: evidence_id)
    end

    def result_evidences(*collections)
      EvidenceCollection.collect(*collections)
    end

    def resolution_record(site, targets, evidences)
      analyzer_profile = profile
      target_ids = targets.map(&:graph_id).uniq.sort
      status = target_ids.empty? ? :unknown : :partial
      ResolutionRecord.new(
        resolution: Resolution.new(
          call_site_id: site.call_site_id,
          target_definition_ids: target_ids,
          status: status,
          unknown_scope: residual_scope(site),
          evidence_ids: result_evidences(evidences).filter_map(&:evidence_id)
        ),
        producer: analyzer_profile.name,
        producer_version: analyzer_profile.version,
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
