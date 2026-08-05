# frozen_string_literal: true

require 'json'

module Necropsy
  module ResolutionStore
    DIAGNOSTIC_SAMPLE_LIMIT = 5
    RESOLUTION_STATUSES = %i[complete partial unknown].freeze

    def resolution_records(call_site_id = nil)
      records = sorted_resolution_records
      return records unless call_site_id

      records.select { |record| record.resolution.call_site_id == call_site_id.to_s }.freeze
    end

    def resolution_status_counts
      counts = RESOLUTION_STATUSES.to_h { |status| [status, 0] }
      sorted_resolution_records.each { |record| counts[record.resolution.status] += 1 }
      counts.freeze
    end

    def resolution_conflicts
      compute_resolution_conflicts
    end

    def resolution_issues
      compute_resolution_issues
    end

    private

    def initialize_resolution_store
      @resolution_records_by_key = {}
      @call_sites_by_id = call_sites.group_by(&:call_site_id)
    end

    def register_result_resolutions(result)
      return unless result.respond_to?(:resolutions)
      return if result.resolutions.nil?

      Array(result.resolutions).each { |record| store_resolution_record(record) }
      rebuild_resolution_derived_state
    end

    def store_resolution_record(record)
      record = ResolutionRecord.from_h(record) unless record.is_a?(ResolutionRecord)
      @resolution_records_by_key[resolution_record_key(record)] = record
    rescue KeyError, ArgumentError, NoMethodError => e
      store_malformed_resolution_issue(record, e)
    end

    def store_malformed_resolution_issue(record, error)
      @malformed_resolution_issues ||= {}
      payload = {
        'kind' => 'malformed_resolution',
        'record' => record.respond_to?(:to_h) ? record.to_h : record.to_s,
        'error_class' => error.class.name,
        'error_message' => error.message
      }
      @malformed_resolution_issues[canonical_payload(payload)] = payload
    end

    def resolution_record_key(record)
      [record.resolution.call_site_id, record.producer, record.producer_version.to_s,
       canonical_payload(record.assumptions), canonical_payload(record.resolution.to_h)]
    end

    def sorted_resolution_records
      @resolution_records_by_key.values.sort_by { |record| resolution_record_key(record) }.freeze
    end

    def rebuild_resolution_derived_state
      remove_blockers_matching { |blocker| resolution_store_blocker?(blocker) }
      resolution_blockers.each { |blocker| add_blocker(blocker) }
      observation['call_site_resolutions'] = resolution_diagnostic
    end

    def resolution_blockers
      blockers = sorted_resolution_records.filter_map { |record| residual_resolution_blocker(record) }
      blockers.concat(resolution_conflicts.map { |conflict| resolution_conflict_blocker(conflict) })
      blockers.concat(resolution_issues.map { |issue| invalid_resolution_blocker(issue) })
      blockers.sort_by { |blocker| canonical_payload(blocker.to_h) }
    end

    def residual_resolution_blocker(record)
      resolution = record.resolution
      return if resolution.status == :complete

      site = unique_call_site(resolution.call_site_id)
      return unless site

      scope = resolution.unknown_scope
      kind = resolution.status == :partial ? :partial_dispatch : :unknown_dispatch
      Blocker.new(
        kind: kind,
        scope_kind: scope.scope_kind,
        scope_value: scope.scope_value,
        source: record.producer,
        reason: resolution_blocker_reason(record),
        suggested_action: :review_receiver_flow,
        metadata: resolution_metadata(record, site, scope)
      )
    end

    def resolution_blocker_reason(record)
      resolution = record.resolution
      if resolution.status == :partial
        "#{record.producer} resolved known targets but left a residual target scope"
      else
        "#{record.producer} could not enumerate a usable target"
      end
    end

    def resolution_metadata(record, site, scope)
      caller = nodes.exact(site.caller_id)
      metadata = {
        'resolution_store' => true,
        'call_site_id' => site.call_site_id,
        'producer' => record.producer,
        'producer_version' => record.producer_version,
        'assumptions' => record.assumptions,
        'known_target_definition_ids' => record.resolution.target_definition_ids,
        'caller_id' => site.caller_id,
        'caller_kind' => caller&.kind&.to_s,
        'caller_domain' => site.test ? 'test' : 'runtime',
        'receiver_kind' => site.receiver_kind.to_s,
        'receiver_name' => site.receiver_name,
        'file' => site.file,
        'line' => site.line,
        'scope_match' => scope.match.to_s
      }
      metadata['message'] = site.message unless %i[message symbol].include?(scope.scope_kind)
      metadata
    end

    def compute_resolution_conflicts
      conflicts = same_producer_conflicts + comparable_resolution_conflicts
      conflicts.uniq { |conflict| canonical_payload(conflict) }
               .sort_by { |conflict| canonical_payload(conflict) }
               .freeze
    end

    def same_producer_conflicts
      sorted_resolution_records.group_by(&:identity_key).filter_map do |identity_key, records|
        next unless records.map { |record| canonical_payload(record.resolution.to_h) }.uniq.length > 1

        conflict_payload('same_producer_divergence', records, identity_key.first)
      end
    end

    def comparable_resolution_conflicts
      sorted_resolution_records.group_by do |record|
        [record.resolution.call_site_id, record.assumptions]
      end.flat_map do |(call_site_id, _assumptions), records|
        complete = records.select { |record| record.resolution.status == :complete }
        partial = records.select { |record| record.resolution.status == :partial }
        complete_conflicts(call_site_id, complete) + complete_partial_conflicts(call_site_id, complete, partial)
      end
    end

    def complete_conflicts(call_site_id, records)
      records.combination(2).filter_map do |left, right|
        next if left.resolution.target_definition_ids == right.resolution.target_definition_ids

        conflict_payload('complete_target_mismatch', [left, right], call_site_id)
      end
    end

    def complete_partial_conflicts(call_site_id, complete, partial)
      complete.product(partial).filter_map do |complete_record, partial_record|
        outside = partial_record.resolution.target_definition_ids - complete_record.resolution.target_definition_ids
        next if outside.empty?

        conflict_payload(
          'partial_target_outside_complete', [complete_record, partial_record], call_site_id,
          'outside_target_definition_ids' => outside.sort
        )
      end
    end

    def conflict_payload(kind, records, call_site_id, details = {})
      {
        'kind' => kind,
        'call_site_id' => call_site_id,
        'producers' => records.map(&:producer).uniq.sort,
        'producer_keys' => records.map(&:identity_key).uniq.sort_by { |key| canonical_payload(key) },
        'target_definition_ids' => records.flat_map do |record|
          record.resolution.target_definition_ids
        end.uniq.sort
      }.merge(details)
    end

    def compute_resolution_issues
      issues = sorted_resolution_records.flat_map do |record|
        resolution_reference_issues(record)
      end
      issues.concat((@malformed_resolution_issues || {}).values)
      issues.uniq { |issue| canonical_payload(issue) }
            .sort_by { |issue| canonical_payload(issue) }
            .freeze
    end

    def resolution_reference_issues(record)
      resolution = record.resolution
      issues = []
      sites = @call_sites_by_id.fetch(resolution.call_site_id, [])
      if sites.length != 1
        issues << resolution_issue(
          sites.empty? ? 'unknown_call_site' : 'ambiguous_call_site', record,
          'matching_call_site_count' => sites.length
        )
      end
      resolution.target_definition_ids.each do |definition_id|
        next if nodes.exact(definition_id)

        issues << resolution_issue('unknown_target_definition', record, 'definition_id' => definition_id)
      end
      issues
    end

    def resolution_issue(kind, record, details)
      {
        'kind' => kind,
        'call_site_id' => record.resolution.call_site_id,
        'producer' => record.producer,
        'producer_version' => record.producer_version
      }.merge(details)
    end

    def resolution_conflict_blocker(conflict)
      site = unique_call_site(conflict.fetch('call_site_id'))
      scope_kind, scope_value = blocker_scope_for_site(site)
      Blocker.new(
        kind: :resolution_conflict,
        scope_kind: scope_kind,
        scope_value: scope_value,
        source: :resolution_store,
        reason: "Conflicting call-site resolutions: #{conflict.fetch('kind')}",
        suggested_action: :review_analyzers,
        metadata: resolution_store_metadata(site).merge(
          'conflict_kind' => conflict.fetch('kind'),
          'producers' => conflict.fetch('producers'),
          'target_definition_ids' => conflict.fetch('target_definition_ids')
        )
      )
    end

    def invalid_resolution_blocker(issue)
      site = unique_call_site(issue['call_site_id'])
      scope_kind, scope_value = blocker_scope_for_site(site)
      Blocker.new(
        kind: :resolution_invalid,
        scope_kind: scope_kind,
        scope_value: scope_value,
        source: :resolution_store,
        reason: "Invalid call-site resolution reference: #{issue.fetch('kind')}",
        suggested_action: :fix_analyzer,
        metadata: resolution_store_metadata(site).merge('resolution_issue' => issue)
      )
    end

    def blocker_scope_for_site(site)
      site ? [:message, site.message] : [:global, '*']
    end

    def resolution_store_metadata(site)
      {
        'resolution_store' => true,
        'call_site_id' => site&.call_site_id,
        'caller_id' => site&.caller_id,
        'caller_domain' => site&.test ? 'test' : 'runtime',
        'message' => site&.message,
        'receiver_kind' => site&.receiver_kind&.to_s,
        'file' => site&.file,
        'line' => site&.line,
        'scope_match' => 'exact'
      }
    end

    def resolution_store_blocker?(blocker)
      blocker.metadata['resolution_store'] || blocker.metadata[:resolution_store]
    end

    def unique_call_site(call_site_id)
      sites = @call_sites_by_id.fetch(call_site_id.to_s, [])
      sites.first if sites.one?
    end

    def resolution_diagnostic
      conflicts = resolution_conflicts
      issues = resolution_issues
      {
        'status_counts' => resolution_status_counts.transform_keys(&:to_s),
        'conflict_count' => conflicts.length,
        'conflicts' => conflicts.first(DIAGNOSTIC_SAMPLE_LIMIT),
        'issue_count' => issues.length,
        'issues' => issues.first(DIAGNOSTIC_SAMPLE_LIMIT)
      }
    end

    def canonical_payload(value)
      JSON.generate(canonical_resolution_value(value))
    end

    def canonical_resolution_value(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).to_h do |key|
          [key.to_s, canonical_resolution_value(value.fetch(key))]
        end
      when Array
        value.map { |item| canonical_resolution_value(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
