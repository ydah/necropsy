# frozen_string_literal: true

require 'digest'

module Necropsy
  module EvidenceStore
    PROJECTIONS = %i[exact conservative observed].freeze

    def self.normalize_projection(projection)
      normalized = projection.to_sym if projection.respond_to?(:to_sym)
      return normalized if PROJECTIONS.include?(normalized)

      raise ArgumentError, "projection must be one of: #{PROJECTIONS.join(', ')}"
    end

    def evidence_records
      @evidence_records_by_id.values.sort_by(&:evidence_id).freeze
    end

    def evidence_record(evidence_id)
      @evidence_records_by_id[evidence_id.to_s]
    end

    def evidence_collisions
      @evidence_collision_payloads.keys.sort.map do |evidence_id|
        {
          'evidence_id' => evidence_id,
          'payload_sha256s' => @evidence_collision_payloads.fetch(evidence_id).to_a.sort,
          'domains' => @evidence_domains.fetch(evidence_id, Set.new).map(&:to_s).sort
        }
      end.freeze
    end

    private

    def initialize_evidence_store
      @evidence_records_by_id = {}
      @evidence_payloads_by_id = {}
      @evidence_payloads_by_object = {}.compare_by_identity
      @evidence_domains = Hash.new { |hash, key| hash[key] = Set.new }
      @quarantined_evidence_ids = Set.new
      @evidence_collision_payloads = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def register_evidence(evidence, domain: :runtime, canonical_payload: nil)
      record = evidence_with_identity(evidence)
      evidence_id = record.evidence_id
      payload = canonical_payload || canonical_evidence_payload(record)
      @evidence_payloads_by_object[record] = [evidence_id, payload]
      @evidence_domains[evidence_id] << domain.to_sym

      if @quarantined_evidence_ids.include?(evidence_id)
        @evidence_collision_payloads[evidence_id] << Digest::SHA256.hexdigest(payload)
        rebuild_evidence_collision_state
        return
      end

      existing_payload = @evidence_payloads_by_id[evidence_id]
      if existing_payload && existing_payload != payload
        @evidence_collision_payloads[evidence_id].merge(
          [Digest::SHA256.hexdigest(existing_payload), Digest::SHA256.hexdigest(payload)]
        )
        quarantine_evidence(evidence_id)
        return
      end

      @evidence_records_by_id[evidence_id] ||= record
      @evidence_payloads_by_id[evidence_id] ||= payload
      refresh_evidence_store_observation if observation.key?('evidence_store')
      evidence_id
    end

    def evidence_with_identity(evidence)
      return evidence if evidence.evidence_id

      evidence.with(evidence_id: EvidenceIdentity.generate(evidence.to_h.except('evidence_id')))
    end

    def canonical_evidence_payload(evidence)
      BoundedCanonicalizer.dump(evidence.to_h.except('evidence_id'))
    end

    def quarantine_evidence(evidence_id)
      @quarantined_evidence_ids << evidence_id
      @evidence_records_by_id.delete(evidence_id)
      @evidence_payloads_by_id.delete(evidence_id)
      remove_evidence_references(evidence_id)
      rebuild_evidence_collision_state
    end

    def remove_evidence_references(evidence_id)
      store.physical_edges.each_value do |callees|
        callees.each_value { |evidence_ids| evidence_ids.delete(evidence_id) }
        callees.delete_if { |_callee_id, evidence_ids| evidence_ids.empty? }
      end
      store.physical_edges.delete_if { |_caller_id, callees| callees.empty? }
      store.dynamic_alive.each_value { |evidence_ids| evidence_ids.delete(evidence_id) }
      store.dynamic_alive.delete_if { |_node_id, evidence_ids| evidence_ids.empty? }
      rebuild_incoming_edges
    end

    def rebuild_evidence_collision_state
      remove_blockers_matching do |blocker|
        blocker.kind == :evidence_collision && blocker.source == :evidence_store
      end
      @evidence_collision_payloads.keys.sort.each do |evidence_id|
        @evidence_domains.fetch(evidence_id).to_a.sort.each do |domain|
          add_blocker(evidence_collision_blocker(evidence_id, domain))
        end
      end
      refresh_evidence_store_observation
    end

    def refresh_evidence_store_observation
      observation['evidence_store'] = {
        'record_count' => @evidence_records_by_id.length,
        'collision_count' => @evidence_collision_payloads.length,
        'collisions' => evidence_collisions.first(5)
      }
    end

    def evidence_collision_blocker(evidence_id, domain)
      Blocker.new(
        kind: :evidence_collision,
        scope_kind: :global,
        scope_value: '*',
        source: :evidence_store,
        reason: 'One evidence ID was supplied with conflicting payloads',
        suggested_action: :fix_analyzer,
        metadata: {
          'caller_domain' => domain.to_s,
          'receiver_kind' => 'implicit',
          'evidence_id' => evidence_id,
          'evidence_store' => true
        }
      )
    end

    def projected_evidence_records(evidence_ids, projection:, scope: nil)
      projection = normalize_projection(projection)
      evidence_ids.filter_map { |evidence_id| evidence_record(evidence_id) }
                  .select { |evidence| evidence_in_projection?(evidence, projection, scope) }
                  .sort_by(&:evidence_id)
    end

    def projected_evidence_ids(evidence_ids, projection:, scope: nil)
      projected_evidence_records(evidence_ids, projection: projection, scope: scope).map(&:evidence_id).freeze
    end

    def normalize_projection(projection)
      EvidenceStore.normalize_projection(projection)
    end

    def evidence_payload_registered?(evidence, canonical_payload: nil)
      evidence_id = evidence.evidence_id
      cached = @evidence_payloads_by_object[evidence]
      return true if cached && cached[0] == evidence_id && @evidence_payloads_by_id[evidence_id] == cached[1]

      payload = canonical_payload || canonical_evidence_payload(evidence)
      return true if @evidence_payloads_by_id[evidence_id] == payload
      return false unless @quarantined_evidence_ids.include?(evidence_id)

      @evidence_collision_payloads.fetch(evidence_id).include?(Digest::SHA256.hexdigest(payload))
    end

    def evidence_in_projection?(evidence, projection, requested_scope)
      grade = evidence.grade&.to_sym
      case projection
      when :conservative
        true
      when :exact
        grade == :exact || (grade == :observed && verified_observed_scope?(evidence.scope, requested_scope))
      when :observed
        grade == :observed && evidence_scope_matches?(evidence.scope, requested_scope)
      end
    end

    def verified_observed_scope?(actual_scope, requested_scope)
      return false unless requested_scope.is_a?(Hash)

      actual_status = actual_scope.is_a?(Hash) && actual_scope['source_revision_status']
      return false if %w[mismatch stale].include?(actual_status.to_s)

      revision = requested_scope['revision'] || requested_scope[:revision]
      revision && evidence_scope_matches?(actual_scope, requested_scope)
    end

    def evidence_scope_matches?(actual_scope, requested_scope)
      return true if requested_scope.nil?

      actual_scope = actual_scope.to_h if actual_scope.respond_to?(:to_h)
      requested_scope = requested_scope.to_h if requested_scope.respond_to?(:to_h)
      return canonical_scope(actual_scope) == canonical_scope(requested_scope) unless requested_scope.is_a?(Hash)
      return false unless actual_scope.is_a?(Hash)

      requested_scope.all? do |key, expected|
        actual_key = [key, key.to_s, key.respond_to?(:to_sym) && key.to_sym].find do |candidate|
          candidate && actual_scope.key?(candidate)
        end
        next false unless actual_key

        actual = actual_scope.fetch(actual_key)
        evidence_scope_matches?(actual, expected)
      end
    rescue KeyError, NoMethodError, BoundedCanonicalizer::Error
      false
    end

    def canonical_scope(value)
      BoundedCanonicalizer.dump(value)
    end
  end
end
