# frozen_string_literal: true

require 'digest'

module Necropsy
  CONFIDENCE_LEVELS = {
    low: 0,
    medium: 1,
    high: 2,
    certain: 3
  }.freeze

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

  Evidence = Data.define(:analyzer, :kind, :weight, :details, :metadata) do
    def to_h
      {
        'analyzer' => analyzer.to_s,
        'kind' => kind.to_s,
        'weight' => weight,
        'details' => details,
        'metadata' => metadata
      }
    end
  end

  Edge = Data.define(:caller_id, :callee_id, :evidences) do
    def to_h
      {
        'caller_id' => caller_id,
        'callee_id' => callee_id,
        'evidences' => evidences.map(&:to_h)
      }
    end
  end

  EntryPoint = Data.define(:node_id, :reason) do
    def test?
      reason == :test_suite
    end

    def to_h
      { 'node_id' => node_id, 'reason' => reason.to_s }
    end
  end

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
    :dynamic
  ) do
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
        'dynamic' => dynamic
      }
    end
  end

  CallSite = Data.define(
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
    def to_h
      {
        'caller_id' => caller_id,
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

  AnalyzerProfile = Data.define(:name, :kind, :soundness, :description) do
    def to_h
      {
        'name' => name.to_s,
        'kind' => kind.to_s,
        'soundness' => soundness.to_s,
        'description' => description
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

  AnalyzerResult = Data.define(:edge_evidences, :alive_evidences, :uncertainties, :observation, :blockers) do
    def initialize(edge_evidences:, alive_evidences:, uncertainties:, observation:, blockers: [])
      super
    end

    def self.empty
      new(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [])
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

    def to_h
      {
        'fingerprint' => fingerprint,
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
