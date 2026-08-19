# frozen_string_literal: true

module Necropsy
  class AnalysisHealthBuilder
    INVALID_BLOCKER_KINDS = %i[
      analyzer_failure blocker_invalid evidence_collision rails_route_health resolution_invalid unsound_rta_pruning
    ].freeze
    DEGRADED_BLOCKER_KINDS = %i[
      reference_scan_incomplete reference_scope_incomplete source_discovery_incomplete
    ].freeze

    def initialize(graph:, initial_snapshot:, final_snapshot:)
      @graph = graph
      @initial_snapshot = initial_snapshot
      @final_snapshot = final_snapshot
    end

    def call
      reasons = snapshot_health_reasons
      graph.blockers.each do |blocker|
        severity = blocker_health_severity(blocker)
        next unless severity

        reasons << blocker_health_reason(blocker, severity)
      end
      AnalysisHealth.from_reasons(reasons.uniq { |reason| BoundedCanonicalizer.dump(reason) })
    end

    private

    attr_reader :graph, :initial_snapshot, :final_snapshot

    def snapshot_health_reasons
      snapshots = { 'initial' => initial_snapshot, 'final' => final_snapshot }
      unavailable = snapshots.filter_map do |phase, snapshot|
        next if snapshot['status'] == 'complete'

        { 'phase' => phase, 'reason' => snapshot['reason'], 'details' => snapshot.except('sha256') }
      end
      return [{ 'severity' => 'invalid', 'code' => 'source_snapshot_unavailable', 'snapshots' => unavailable }] if unavailable.any?
      return [] if initial_snapshot['sha256'] == final_snapshot['sha256']

      [{
        'severity' => 'invalid',
        'code' => 'source_changed_during_analysis',
        'initial_sha256' => initial_snapshot['sha256'],
        'final_sha256' => final_snapshot['sha256']
      }]
    end

    def blocker_health_severity(blocker)
      return :invalid if blocker.kind == :parse_incomplete && blocker.caller_domain == :runtime
      return :invalid if INVALID_BLOCKER_KINDS.include?(blocker.kind)

      :degraded if DEGRADED_BLOCKER_KINDS.include?(blocker.kind)
    end

    def blocker_health_reason(blocker, severity)
      metadata = blocker.metadata
      {
        'severity' => severity.to_s,
        'code' => blocker.kind.to_s,
        'message' => blocker.reason,
        'source' => blocker.source.respond_to?(:to_h) ? blocker.source.to_h : blocker.source.to_s,
        'file' => metadata['file'] || metadata[:file],
        'line' => metadata['line'] || metadata[:line]
      }.compact
    end
  end
end
