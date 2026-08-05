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
  end
end
