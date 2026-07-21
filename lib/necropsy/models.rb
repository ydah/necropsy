# frozen_string_literal: true

require 'digest'

module Necropsy
  CONFIDENCE_LEVELS = {
    low: 0,
    medium: 1,
    high: 2,
    certain: 3
  }.freeze

  Node = Data.define(:id, :kind, :file, :line, :end_line, :defined_via, :owner, :name, :test, :visibility) do
    def method?
      kind != :block_entry
    end

    def fingerprint(classification)
      Digest::SHA256.hexdigest("#{classification}:#{id}")
    end

    def to_h
      {
        'id' => id,
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

  AnalyzerResult = Data.define(:edge_evidences, :alive_evidences, :uncertainties, :observation) do
    def self.empty
      new(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {})
    end
  end

  Finding = Data.define(:node, :classification, :confidence, :score, :reasons, :evidences) do
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
        'node' => node.to_h,
        'reasons' => reasons,
        'evidences' => evidences.map(&:to_h)
      }
    end
  end
end
