# frozen_string_literal: true

module Necropsy
  class WhyNotExplanation
    SCHEMA_VERSION = 'necropsy.why-not.v1'
    ITEM_LIMIT = 100
    RESOLUTIONS_PER_SITE_LIMIT = 20
    NESTED_DEPTH_LIMIT = 12
    STRING_BYTES_LIMIT = 4_096
    BOUNDS_KEY = '_bounds'
    RESOLUTION_STATUSES = %w[complete partial unknown unrecorded].freeze
    RESOLUTION_BLOCKERS = %i[unknown_dispatch partial_dispatch resolution_conflict resolution_invalid].freeze

    def initialize(report)
      @report = report
      @graph = report.graph
    end

    def call(node)
      finding = report.findings.find { |candidate| candidate.node.graph_id == node.graph_id }
      blockers = canonical_sort(finding ? finding.blockers : graph.matching_blockers(node))
      all_records = graph.resolution_records
      records_by_site = all_records.group_by { |record| record.resolution.call_site_id }
      sites = incoming_call_sites(node, records_by_site)
      site_records = sites.to_h { |site| [site.call_site_id, records_by_site.fetch(site.call_site_id, [])] }
      rejections = target_rejections(node, site_records)
      definitions = graph.definitions_for(node.symbol_id)
      state = state(node, finding)
      risks = risk_flags(node, definitions, blockers)
      assumption_values = assumptions(site_records.values.flatten)
      suggestions = suggested_next_evidence(finding, blockers, sites)

      payload = {
        'schema_version' => SCHEMA_VERSION,
        'status' => 'why_not',
        'state' => state,
        'action' => action(state, risks),
        'risk_flags' => risks,
        'classification' => finding&.classification&.to_s,
        'confidence' => finding&.confidence&.to_s,
        'artifact_context' => artifact_context(node),
        'physical_definition' => node.to_h,
        'same_name_definitions' => definitions.first(ITEM_LIMIT).map(&:to_h),
        'same_name_definition_summary' => bounded_summary(definitions.length, ITEM_LIMIT),
        'reachability_or_absence' => reachability_or_absence(node, sites, blockers),
        'incoming_call_sites_examined' => sites.first(ITEM_LIMIT).map do |site|
          call_site_payload(site, node, site_records.fetch(site.call_site_id))
        end,
        'incoming_call_site_summary' => bounded_summary(sites.length, ITEM_LIMIT),
        'resolution_status' => resolution_status(site_records),
        'target_rejection_reasons' => rejections.first(ITEM_LIMIT),
        'target_rejection_summary' => bounded_summary(rejections.length, ITEM_LIMIT),
        'blockers' => blockers.first(ITEM_LIMIT).map(&:to_h),
        'blocker_summary' => bounded_summary(blockers.length, ITEM_LIMIT),
        'unknown_or_partial_blockers' => bounded_blockers(
          blockers.select { |blocker| resolution_blocker?(blocker) }
        ),
        'unknown_or_partial_blocker_summary' => bounded_summary(
          blockers.count { |blocker| resolution_blocker?(blocker) }, ITEM_LIMIT
        ),
        'world_and_root_policy' => world_and_root_policy(node),
        'non_ruby_matches' => bounded_blockers(
          blockers.select { |blocker| blocker.kind == :unparsed_external_reference }
        ),
        'non_ruby_match_summary' => bounded_summary(
          blockers.count { |blocker| blocker.kind == :unparsed_external_reference }, ITEM_LIMIT
        ),
        'parse_and_analyzer_failures' => failure_payload(node, blockers),
        'enabled_rules_and_types' => enabled_rules_and_types,
        'assumptions' => bounded_values(assumption_values),
        'assumption_summary' => bounded_summary(assumption_values.length, ITEM_LIMIT),
        'suggested_next_evidence' => suggestions.first(ITEM_LIMIT),
        'suggested_next_evidence_summary' => bounded_summary(suggestions.length, ITEM_LIMIT),
        'limits' => {
          'items_per_collection' => ITEM_LIMIT,
          'resolutions_per_call_site' => RESOLUTIONS_PER_SITE_LIMIT
        }
      }
      bounded_payload(payload)
    end

    private

    attr_reader :report, :graph

    def state(node, finding)
      return 'blocked' if finding&.classification == :blocked
      return 'test_only' if finding&.classification == :test_only_reachable
      return 'candidate' if finding
      return 'runtime_reachable' if report.reachability.runtime_paths.key?(node.graph_id)
      return 'external_reachable' if report.reachability.external_paths.key?(node.graph_id)
      return 'test_only' if report.reachability.test_paths.key?(node.graph_id)

      'not_classified'
    end

    def action(state, risks)
      case state
      when 'runtime_reachable', 'external_reachable' then 'keep'
      when 'test_only' then 'observe'
      when 'blocked' then 'review'
      when 'candidate' then risks.empty? ? 'verify' : 'review'
      else 'verify'
      end
    end

    def risk_flags(node, definitions, blockers)
      flags = []
      flags << 'public_or_protected_visibility' if %i[public protected].include?(node.visibility)
      flags << 'generated_method' unless %i[def defs define_method].include?(node.defined_via)
      flags << 'duplicate_or_redefinition' if definitions.length > 1
      flags << 'no_owner' if node.owner.nil? || node.owner.empty?
      flags << 'test_definition' if node.test
      flags << 'dynamic_owner' if graph.class_info(node.owner)&.dynamic
      flags << 'analysis_incomplete' if blockers.any?
      flags.sort
    end

    def incoming_call_sites(node, records_by_site)
      graph.call_sites.select do |site|
        records = records_by_site.fetch(site.call_site_id, [])
        site.message.to_s == node.name.to_s || records.any? { |record| resolution_mentions?(record, node.graph_id) }
      end.sort_by { |site| [site.file.to_s, site.line.to_i, site.call_site_id.to_s] }
    end

    def resolution_mentions?(record, definition_id)
      resolution = record.resolution
      resolution.target_definition_ids.include?(definition_id) ||
        resolution.rejected_targets.any? { |target| target.definition_id == definition_id }
    end

    def call_site_payload(site, node, records)
      displayed = records.first(RESOLUTIONS_PER_SITE_LIMIT)
      {
        'call_site' => bounded_call_site(site),
        'resolution_statuses' => records.empty? ? ['unrecorded'] : records.map { |record| record.resolution.status.to_s }.uniq.sort,
        'resolutions' => displayed.map { |record| examined_resolution(record, node) },
        'resolution_summary' => bounded_summary(records.length, RESOLUTIONS_PER_SITE_LIMIT)
      }
    end

    def examined_resolution(record, node)
      resolution = record.resolution
      rejected = canonical_sort(resolution.rejected_targets)
      {
        'producer' => record.producer,
        'producer_version' => record.producer_version,
        'status' => resolution.status.to_s,
        'matches_physical_definition' => resolution.target_definition_ids.include?(node.graph_id),
        'target_definition_ids' => resolution.target_definition_ids.first(ITEM_LIMIT),
        'target_definition_summary' => bounded_summary(resolution.target_definition_ids.length, ITEM_LIMIT),
        'unknown_scope' => resolution.unknown_scope&.to_h,
        'rejected_targets' => rejected.first(ITEM_LIMIT).map(&:to_h),
        'rejected_target_summary' => bounded_summary(rejected.length, ITEM_LIMIT),
        'evidence_ids' => resolution.evidence_ids.first(ITEM_LIMIT),
        'evidence_summary' => bounded_summary(resolution.evidence_ids.length, ITEM_LIMIT),
        'assumptions' => record.assumptions.first(ITEM_LIMIT),
        'assumption_summary' => bounded_summary(record.assumptions.length, ITEM_LIMIT)
      }
    end

    def bounded_call_site(site)
      payload = site.to_h.except('metadata')
      metadata = site.metadata
      receiver_candidates = Array(metadata['receiver_candidates'] || metadata[:receiver_candidates])
      payload['metadata'] = {
        'original_message' => metadata['original_message'] || metadata[:original_message],
        'implicit_from' => metadata['implicit_from'] || metadata[:implicit_from],
        'receiver_candidates' => receiver_candidates.first(ITEM_LIMIT),
        'receiver_candidate_summary' => bounded_summary(receiver_candidates.length, ITEM_LIMIT)
      }.compact
      payload
    end

    def resolution_status(resolutions)
      counts = RESOLUTION_STATUSES.to_h { |status| [status, 0] }
      resolutions.each_value do |records|
        if records.empty?
          counts['unrecorded'] += 1
        else
          records.each { |record| counts[record.resolution.status.to_s] += 1 }
        end
      end
      counts
    end

    def target_rejections(node, resolutions)
      values = resolutions.flat_map do |call_site_id, records|
        records.flat_map do |record|
          record.resolution.rejected_targets.filter_map do |target|
            next unless target.definition_id == node.graph_id

            target.to_h.merge('call_site_id' => call_site_id, 'producer' => record.producer)
          end
        end
      end
      canonical_sort(values)
    end

    def resolution_blocker?(blocker)
      RESOLUTION_BLOCKERS.include?(blocker.kind.to_sym)
    end

    def world_and_root_policy(node)
      policy = graph.observation.fetch('world_policy', { 'world' => 'unknown', 'load_roots' => 'unknown' })
      roots = canonical_sort(graph.entry_points.select { |root| root.definition_id == node.graph_id })
      root_rules = graph.entry_points.map { |root| root.reason.to_s }.uniq.sort
      {
        'world' => policy.fetch('world'),
        'load_roots' => policy.fetch('load_roots'),
        'matching_roots' => roots.first(ITEM_LIMIT).map(&:to_h),
        'matching_root_summary' => bounded_summary(roots.length, ITEM_LIMIT),
        'enabled_root_rules' => root_rules.first(ITEM_LIMIT),
        'enabled_root_rule_summary' => bounded_summary(root_rules.length, ITEM_LIMIT),
        'reachable_domains' => reachable_domains(node)
      }
    end

    def reachable_domains(node)
      id = node.graph_id
      { 'runtime' => report.reachability.runtime_paths, 'external' => report.reachability.external_paths,
        'test' => report.reachability.test_paths }.filter_map { |domain, paths| domain if paths.key?(id) }
    end

    def reachability_or_absence(node, sites, blockers)
      domain = %i[runtime external test].find { |candidate| report.reachability.witness(node.graph_id, kind: candidate) }
      unless domain
        return {
          'kind' => 'absence',
          'runtime_witness' => false,
          'external_witness' => false,
          'examined_incoming_call_sites' => sites.length,
          'matching_blockers' => blockers.length
        }
      end

      path = report.reachability.witness(node.graph_id, kind: domain)
      root_id = path.first
      roots = canonical_sort(graph.entry_points.select do |root|
        root.definition_id == root_id && root.domain == domain
      end)
      {
        'kind' => 'witness',
        'domain' => domain.to_s,
        'definition_ids' => path.first(ITEM_LIMIT),
        'path_summary' => bounded_summary(path.length, ITEM_LIMIT),
        'root' => roots.first&.to_h,
        'path_length' => path.length
      }
    end

    def failure_payload(node, blockers)
      parse_blockers = blockers.select { |blocker| blocker.kind == :parse_incomplete }
      affected_files = parse_blockers.filter_map { |blocker| blocker.metadata['file'] }.uniq
      affected_files << node.file if graph.file_statuses.fetch(node.file, :complete) != :complete
      parse_failures = canonical_sort(graph.source_errors.select { |error| affected_files.include?(error.file) })
      analyzer_failures = blockers.select { |blocker| blocker.kind == :analyzer_failure }
      {
        'parse_failures' => parse_failures.first(ITEM_LIMIT).map(&:to_h),
        'parse_failure_summary' => bounded_summary(parse_failures.length, ITEM_LIMIT),
        'parse_blockers' => parse_blockers.first(ITEM_LIMIT).map(&:to_h),
        'parse_blocker_summary' => bounded_summary(parse_blockers.length, ITEM_LIMIT),
        'analyzer_failures' => analyzer_failures.first(ITEM_LIMIT).map(&:to_h),
        'analyzer_failure_summary' => bounded_summary(analyzer_failures.length, ITEM_LIMIT)
      }
    end

    def artifact_context(node)
      policy = graph.observation.fetch('world_policy', {})
      source_snapshot = report.source_snapshot || {
        'status' => 'unavailable', 'sha256' => 'unavailable', 'reason' => 'project_context_unavailable'
      }
      {
        'tool_version' => Necropsy::VERSION,
        'source_digest' => source_snapshot.fetch('sha256'),
        'source_snapshot' => source_snapshot,
        'definition_body_digest' => node.body_digest || 'unavailable',
        'configuration_sha256' => policy.fetch('configuration_sha256', 'unavailable')
      }
    end

    def enabled_rules_and_types
      profiles = canonical_sort(graph.profiles)
      types = profiles.select { |profile| profile.kind.to_s == 'type' }
      {
        'analyzers' => profiles.first(ITEM_LIMIT).map(&:to_h),
        'analyzer_summary' => bounded_summary(profiles.length, ITEM_LIMIT),
        'resolution_producers' => resolution_producers.first(ITEM_LIMIT),
        'resolution_producer_summary' => bounded_summary(resolution_producers.length, ITEM_LIMIT),
        'root_rules' => root_rules.first(ITEM_LIMIT),
        'root_rule_summary' => bounded_summary(root_rules.length, ITEM_LIMIT),
        'type_providers' => types.first(ITEM_LIMIT).map(&:to_h),
        'type_provider_summary' => bounded_summary(types.length, ITEM_LIMIT)
      }
    end

    def resolution_producers
      graph.resolution_records.map(&:producer).uniq.sort
    end

    def root_rules
      graph.entry_points.map { |root| root.reason.to_s }.uniq.sort
    end

    def assumptions(records)
      (graph.profiles.flat_map(&:assumptions) + records.flat_map(&:assumptions)).uniq.sort
    end

    def suggested_next_evidence(finding, blockers, sites)
      suggestions = blockers.map { |blocker| blocker_suggestion(blocker) }
      suggestions << state_suggestion(finding, sites) if suggestions.empty?
      canonical_sort(suggestions.compact.uniq { |suggestion| BoundedCanonicalizer.dump(suggestion) })
    end

    def blocker_suggestion(blocker)
      details = blocker.metadata
      location = [details['file'], details['line']].compact.join(':')
      {
        'kind' => blocker.suggested_action.to_s,
        'details' => [blocker.reason, location.empty? ? nil : "Inspect #{location}"].compact.join('. ')
      }
    end

    def state_suggestion(finding, sites)
      if finding&.classification == :test_only_reachable
        { 'kind' => 'observe_runtime', 'details' => 'Exercise the definition through a representative runtime entry point.' }
      elsif sites.empty?
        { 'kind' => 'find_callers', 'details' => 'Add an explicit root/caller or representative runtime observation.' }
      else
        { 'kind' => 'observe_call_sites', 'details' => 'Capture runtime receiver and target identities for the examined call sites.' }
      end
    end

    def bounded_blockers(values)
      values.first(ITEM_LIMIT).map(&:to_h)
    end

    def bounded_values(values)
      values.first(ITEM_LIMIT)
    end

    def bounded_summary(total, limit)
      returned = [total, limit].min
      { 'total' => total, 'returned' => returned, 'truncated' => total - returned }
    end

    def canonical_sort(values)
      values.sort_by do |value|
        payload = value.respond_to?(:to_h) ? value.to_h : value
        BoundedCanonicalizer.dump(bounded_payload(payload))
      end
    end

    def bounded_payload(value, depth = 0)
      return { '_truncated' => 'depth_limit' } if depth >= NESTED_DEPTH_LIMIT

      value = value.to_h if !value.is_a?(Hash) && !value.is_a?(Array) && value.respond_to?(:to_h)
      case value
      when Hash then bounded_hash(value, depth)
      when Array then value.first(ITEM_LIMIT).map { |entry| bounded_payload(entry, depth + 1) }
      when String then bounded_string(value)
      when Numeric, TrueClass, FalseClass, NilClass then value
      else bounded_string(value.to_s)
      end
    end

    def bounded_hash(value, depth)
      entries = resolved_hash_entries(value)
      value_bounds = {}
      entries.first(ITEM_LIMIT).each_with_object({}) do |(key, entry), result|
        result[key] = bounded_payload(entry, depth + 1)
        value_bounds[key] = { 'collection' => bounded_summary(entry.length, ITEM_LIMIT) } if entry.is_a?(Array)
        if entry.is_a?(String) && entry.bytesize > STRING_BYTES_LIMIT
          value_bounds[key] ||= {}
          value_bounds[key]['bytes'] = { 'total' => entry.bytesize, 'returned' => STRING_BYTES_LIMIT }
        end
      end.tap do |result|
        bounds = {}
        bounds['fields'] = bounded_summary(entries.length, ITEM_LIMIT) if entries.length > ITEM_LIMIT
        bounds['values'] = value_bounds unless value_bounds.empty?
        result[BOUNDS_KEY] = bounds unless bounds.empty?
      end
    end

    def resolved_hash_entries(value)
      entries = value.map do |key, entry|
        identity = hash_key_identity(key)
        [bounded_key(key), identity, BoundedCanonicalizer.dump(bounded_payload(entry)), entry]
      end
      counts = entries.each_with_object(Hash.new(0)) { |(key, _identity, _value, _entry), result| result[key] += 1 }
      occupied = entries.to_h { |key, _identity, _value, _entry| [key, true] }
      occupied[BOUNDS_KEY] = true

      entries.sort_by { |key, identity, entry_identity, _entry| [key, identity, entry_identity] }.map do |key, identity, _entry_identity, entry|
        resolved = if counts[key] == 1 && key != BOUNDS_KEY
                     key
                   else
                     collision_safe_key(key, identity, occupied)
                   end
        occupied[resolved] = true
        [resolved, entry]
      end.sort_by(&:first)
    end

    def hash_key_identity(key)
      type = key.class.name || key.class.to_s
      value = case key
              when String then key.b
              when Symbol then key.to_s.b
              else BoundedCanonicalizer.dump(bounded_payload(key)).b
              end
      "#{type}\0".b + value
    end

    def collision_safe_key(key, identity, occupied)
      digest = Digest::SHA256.hexdigest(identity)
      attempt = 0
      loop do
        suffix = attempt.zero? ? "[#{digest}]" : "[#{digest}:#{attempt}]"
        candidate = bounded_key("#{key}#{suffix}")
        return candidate unless occupied.key?(candidate)

        attempt += 1
      end
    end

    def bounded_string(value)
      normalized = value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      return normalized if normalized.bytesize <= STRING_BYTES_LIMIT

      suffix = "\u2026:#{Digest::SHA256.hexdigest(value.b)}"
      "#{utf8_prefix(normalized, STRING_BYTES_LIMIT - suffix.bytesize)}#{suffix}"
    end

    def bounded_key(value)
      bounded_string(value.to_s)
    end

    def utf8_prefix(value, byte_limit)
      prefix = value.byteslice(0, byte_limit)
      prefix = prefix.byteslice(0, prefix.bytesize - 1) until prefix.valid_encoding?

      prefix
    end
  end
end
