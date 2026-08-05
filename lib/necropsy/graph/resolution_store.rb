# frozen_string_literal: true

require 'digest'

module Necropsy
  module ResolutionStore
    DIAGNOSTIC_SAMPLE_LIMIT = 5
    INVALID_SCOPE_LIMIT = 8
    RESOLUTION_STATUSES = %i[complete partial unknown].freeze
    EMPTY_RESOLUTION_RECORDS = [].freeze

    def resolution_records(call_site_id = nil)
      records = sorted_resolution_records
      return records unless call_site_id

      resolution_records_by_call_site.fetch(call_site_id.to_s, EMPTY_RESOLUTION_RECORDS)
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
      @malformed_resolution_issues = {}
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
      @sorted_resolution_records = nil
      @resolution_records_by_call_site = nil
    rescue KeyError, ArgumentError, NoMethodError, BoundedCanonicalizer::Error, SystemStackError => e
      store_malformed_resolution_issue(record, e)
    end

    def store_malformed_resolution_issue(record, error)
      payload = {
        'kind' => 'malformed_resolution',
        'record' => malformed_record_payload(record),
        'error_class' => error.class.name
      }
      @malformed_resolution_issues[canonical_payload(payload)] = payload
    end

    def malformed_record_payload(record)
      value = record.respond_to?(:to_h) ? record.to_h : record
      canonical = BoundedCanonicalizer.dump(
        value,
        max_depth: 32,
        max_items: 2_000,
        max_string_bytes: 16_384,
        max_total_bytes: 65_536
      )
      {
        'type' => record.class.name.to_s,
        'canonical_bytes' => canonical.bytesize,
        'canonical_sha256' => Digest::SHA256.hexdigest(canonical)
      }
    rescue StandardError, SystemStackError => e
      {
        'unavailable_type' => record.class.name.to_s,
        'canonicalization_error' => e.class.name,
        'canonicalization_code' => canonicalization_error_code(e)
      }
    end

    def canonicalization_error_code(error)
      return 'cycle' if error.is_a?(BoundedCanonicalizer::CycleError)
      return 'unsupported_type' if error.is_a?(BoundedCanonicalizer::UnsupportedTypeError)
      return 'canonicalization_failure' unless error.is_a?(BoundedCanonicalizer::LimitError)
      return 'depth_limit' if error.message.include?('depth')
      return 'item_limit' if error.message.include?('item count')
      return 'string_limit' if error.message.include?('string')

      'size_limit'
    rescue StandardError, SystemStackError
      'canonicalization_failure'
    end

    def resolution_record_key(record)
      [record.resolution.call_site_id, record.producer, record.producer_version.to_s,
       canonical_payload(record.assumptions), canonical_payload(record.resolution.to_h)]
    end

    def resolution_record_identity(record)
      "resolution:v1:#{Digest::SHA256.hexdigest(canonical_payload(record.to_h))}"
    end

    def sorted_resolution_records
      @sorted_resolution_records ||= @resolution_records_by_key.values.sort_by do |record|
        resolution_record_key(record)
      end.freeze
    end

    def resolution_records_by_call_site
      @resolution_records_by_call_site ||= sorted_resolution_records.group_by do |record|
        record.resolution.call_site_id
      end.transform_values(&:freeze).freeze
    end

    def rebuild_resolution_derived_state
      remove_blockers_matching { |blocker| resolution_store_blocker?(blocker) }
      resolution_blockers.each { |blocker| add_blocker(blocker) }
      observation['call_site_resolutions'] = resolution_diagnostic
    end

    def refresh_resolution_derived_state
      return if @resolution_records_by_key.empty? && @malformed_resolution_issues.empty?

      rebuild_resolution_derived_state
    end

    def resolution_blockers
      blockers = sorted_resolution_records.filter_map { |record| residual_resolution_blocker(record) }
      blockers.concat(resolution_conflicts.flat_map { |conflict| resolution_conflict_blockers(conflict) })
      blockers.concat(resolution_issues.flat_map { |issue| invalid_resolution_blockers(issue) })
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
        'resolution_record_id' => resolution_record_identity(record),
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
      }.merge(call_site_visibility_metadata(site))
      metadata['message'] = site.message unless %i[message symbol].include?(scope.scope_kind)
      metadata
    end

    def call_site_visibility_metadata(site)
      metadata = site&.metadata || {}
      result = {}
      original_message = metadata['original_message'] || metadata[:original_message]
      result['original_message'] = original_message.to_s if original_message
      if metadata.key?('include_private') || metadata.key?(:include_private)
        result['include_private'] = metadata.fetch('include_private') { metadata[:include_private] }
      end
      result
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
      issues.concat(@malformed_resolution_issues.values)
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
        unless nodes.exact(definition_id)
          issues << resolution_issue('unknown_target_definition', record, 'definition_id' => definition_id)
          next
        end
        next unless sites.one?
        next if edges_from(sites.first.caller_id).key?(definition_id)

        issues << resolution_issue('missing_target_edge', record, 'definition_id' => definition_id)
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

    def resolution_conflict_blockers(conflict)
      target_ids = Array(conflict['target_definition_ids']).map(&:to_s).uniq.sort
      return [] if target_ids.empty?

      blocker_contexts(conflict.fetch('call_site_id')).map do |context|
        Blocker.new(
          kind: :resolution_conflict,
          scope_kind: :definition,
          scope_value: target_ids,
          source: :resolution_store,
          reason: "Conflicting call-site resolutions: #{conflict.fetch('kind')}",
          suggested_action: :review_analyzers,
          metadata: resolution_store_metadata(context, include_message: false).merge(
            'conflict_kind' => conflict.fetch('kind'),
            'producers' => conflict.fetch('producers'),
            'target_definition_ids' => target_ids
          )
        )
      end
    end

    def invalid_resolution_blockers(issue)
      blocker_contexts(issue['call_site_id']).map do |context|
        context = context.merge(visibility_mode: :unrestricted) if issue['kind'] == 'missing_target_edge'
        scope_kind, scope_value = invalid_resolution_scope(issue, context)
        include_message = scope_kind == :message
        Blocker.new(
          kind: :resolution_invalid,
          scope_kind: scope_kind,
          scope_value: scope_value,
          source: :resolution_store,
          reason: "Invalid call-site resolution reference: #{issue.fetch('kind')}",
          suggested_action: :fix_analyzer,
          metadata: resolution_store_metadata(context, include_message: include_message).merge(
            'resolution_issue' => issue
          )
        )
      end
    end

    def invalid_resolution_scope(issue, context)
      return [:definition, [issue.fetch('definition_id')]] if issue['kind'] == 'missing_target_edge'

      [context.fetch(:scope_kind), context.fetch(:scope_value)]
    end

    def blocker_contexts(call_site_id)
      sites = @call_sites_by_id.fetch(call_site_id.to_s, [])
      return [unknown_blocker_context] if sites.empty?

      grouped = sites.group_by do |site|
        [site.test ? :test : :runtime, site.message.to_s, site_visibility_mode(site)]
      end
      if grouped.length <= INVALID_SCOPE_LIMIT
        return grouped.sort_by { |key, _sites| key.map(&:to_s) }
                      .map { |key, values| site_blocker_context(key, values) }
      end

      sites.group_by { |site| site.test ? :test : :runtime }.sort_by { |domain, _| domain.to_s }.map do |domain, values|
        {
          site: deterministic_site(values), domain: domain, scope_kind: :global, scope_value: '*',
          visibility_mode: :unrestricted
        }
      end
    end

    def unknown_blocker_context
      {
        site: nil, domain: :runtime, scope_kind: :global, scope_value: '*', visibility_mode: :unrestricted
      }
    end

    def site_blocker_context(key, sites)
      domain, message, visibility_mode = key
      {
        site: deterministic_site(sites), domain: domain, scope_kind: :message, scope_value: message,
        visibility_mode: visibility_mode
      }
    end

    def deterministic_site(sites)
      sites.min_by { |site| [site.caller_id.to_s, site.file.to_s, site.line.to_i, site.call_site_id.to_s] }
    end

    def site_visibility_mode(site)
      metadata = site.metadata || {}
      original_message = (metadata['original_message'] || metadata[:original_message])&.to_s
      include_private = metadata.fetch('include_private') { metadata[:include_private] }
      return :unrestricted if %w[send __send__ method].include?(original_message)
      return :unrestricted if original_message == 'respond_to?' && include_private
      return :unrestricted if %i[implicit self super].include?(site.receiver_kind.to_sym)
      return :public_only if original_message == 'public_send'

      :non_private
    end

    def resolution_store_metadata(context, include_message: true)
      site = context.fetch(:site)
      metadata = {
        'resolution_store' => true,
        'call_site_id' => site&.call_site_id,
        'caller_id' => site&.caller_id,
        'caller_domain' => context.fetch(:domain).to_s,
        'receiver_kind' => site&.receiver_kind&.to_s,
        'file' => site&.file,
        'line' => site&.line,
        'scope_match' => 'exact'
      }.merge(call_site_visibility_metadata(site))
      apply_context_visibility!(metadata, context[:visibility_mode])
      metadata['message'] = site.message if include_message && site
      metadata
    end

    def apply_context_visibility!(metadata, visibility_mode)
      metadata.delete('original_message')
      metadata.delete('include_private')
      case visibility_mode
      when :unrestricted
        metadata['receiver_kind'] = 'implicit'
      when :public_only
        metadata['original_message'] = 'public_send'
      when :non_private
        metadata['receiver_kind'] = 'constant'
      end
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
      BoundedCanonicalizer.dump(value)
    end
  end
end
