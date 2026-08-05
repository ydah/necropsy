# frozen_string_literal: true

module Necropsy
  class WhyNotRenderer
    def initialize(payload)
      @payload = payload
    end

    def render
      lines = heading
      append_definitions(lines)
      append_policy(lines)
      append_call_sites(lines)
      append_blockers(lines)
      append_special_diagnostics(lines)
      append_rules(lines)
      append_suggestions(lines)
      lines.join("\n")
    end

    private

    attr_reader :payload

    def heading
      node = payload.fetch('physical_definition')
      [
        "Why-not (#{payload.fetch('state')}): #{node_reference(node)}",
        "Physical definition: #{node['file']}:#{node['line']} #{node['kind']} visibility=#{node['visibility']}",
        "Classification: #{payload['classification'] || 'none'} confidence=#{payload['confidence'] || 'none'}",
        "Action: #{payload.fetch('action')}; risks=#{list_or_none(payload.fetch('risk_flags'))}",
        "Schema: #{payload.fetch('schema_version')}",
        artifact_context
      ]
    end

    def artifact_context
      artifact = payload.fetch('artifact_context')
      "Artifact context: tool=#{artifact['tool_version']} source=#{artifact['source_digest']} " \
        "config=#{artifact['configuration_sha256']}"
    end

    def append_definitions(lines)
      definitions = payload.fetch('same_name_definitions')
      summary = payload.fetch('same_name_definition_summary')
      lines << "Same-name physical definitions: #{summary.fetch('total')} (shown #{summary.fetch('returned')})"
      definitions.each do |definition|
        lines << "  #{node_reference(definition)} at #{definition['file']}:#{definition['line']}"
      end
    end

    def append_policy(lines)
      policy = payload.fetch('world_and_root_policy')
      domains = policy.fetch('reachable_domains')
      lines << "World/root policy: world=#{policy['world']} load_roots=#{policy['load_roots']} " \
               "reachable=#{domains.empty? ? 'none' : domains.join(',')}"
      roots = policy.fetch('matching_roots')
      root_summary = policy.fetch('matching_root_summary')
      lines << "Matching roots: #{roots.empty? ? 'none' : roots.map { |root| root['reason'] }.join(', ')} " \
               "(#{root_summary.fetch('returned')}/#{root_summary.fetch('total')})"
      lines << "Enabled root rules: #{list_or_none(policy.fetch('enabled_root_rules'))}"
      rule_summary = policy.fetch('enabled_root_rule_summary')
      lines << "  ... #{rule_summary.fetch('truncated')} root rules omitted" if rule_summary.fetch('truncated').positive?
      explanation = payload.fetch('reachability_or_absence')
      line = if explanation.fetch('kind') == 'witness'
               "Witness: #{explanation.fetch('domain')} #{explanation.fetch('definition_ids').join(' -> ')}"
             else
               "Absence: no runtime/external witness; examined=#{explanation.fetch('examined_incoming_call_sites')} " \
                 "blockers=#{explanation.fetch('matching_blockers')}"
             end
      lines << line
      path_summary = explanation['path_summary']
      lines << "  ... #{path_summary.fetch('truncated')} witness steps omitted" if path_summary&.fetch('truncated')&.positive?
    end

    def append_call_sites(lines)
      sites = payload.fetch('incoming_call_sites_examined')
      summary = payload.fetch('incoming_call_site_summary')
      lines << "Incoming call sites examined: #{summary.fetch('total')} (shown #{summary.fetch('returned')})"
      sites.each do |examined|
        site = examined.fetch('call_site')
        lines << "  #{site['file']}:#{site['line']} caller=#{site['caller_id']} " \
                 "receiver=#{site['receiver_kind']}:#{site['receiver_name']} message=#{site['message']}"
        lines << "    resolution=#{examined.fetch('resolution_statuses').join(',')}"
        examined.fetch('resolutions').each { |resolution| append_resolution(lines, resolution) }
        resolution_summary = examined.fetch('resolution_summary')
        lines << "    ... #{resolution_summary.fetch('truncated')} resolutions omitted" if resolution_summary.fetch('truncated').positive?
      end
      counts = payload.fetch('resolution_status')
      lines << "Resolution status: #{counts.map { |status, count| "#{status}=#{count}" }.join(', ')}"
      lines << "  ... #{summary.fetch('truncated')} call sites omitted" if summary.fetch('truncated').positive?
    end

    def append_resolution(lines, resolution)
      match = resolution['matches_physical_definition'] ? 'matched' : 'not-matched'
      lines << "      #{resolution['producer']} status=#{resolution['status']} target=#{match}"
      Array(resolution['rejected_targets']).each do |target|
        lines << "        rejected #{target['definition_id']}: #{target['reason']}"
      end
      rejection_summary = resolution.fetch('rejected_target_summary')
      lines << "        ... #{rejection_summary.fetch('truncated')} rejected targets omitted" if rejection_summary.fetch('truncated').positive?
      scope = resolution['unknown_scope']
      lines << "        residual #{scope['scope_kind']}=#{scope['scope_value'].inspect}" if scope
    end

    def append_blockers(lines)
      blockers = payload.fetch('blockers')
      unknown_summary = payload.fetch('unknown_or_partial_blocker_summary')
      blocker_summary = payload.fetch('blocker_summary')
      lines << "Unknown/partial blockers: #{unknown_summary.fetch('total')}"
      lines << "Matching blockers: #{blocker_summary.fetch('total')} (shown #{blocker_summary.fetch('returned')})"
      blockers.each do |blocker|
        metadata = blocker.fetch('metadata', {})
        location = [metadata['file'], metadata['line']].compact.join(':')
        location = " at #{location}" unless location.empty?
        lines << "  blocker #{blocker['kind']}#{location}: #{blocker['reason']}"
      end
      unknown_ids = unknown_blocker_keys(blockers)
      payload.fetch('unknown_or_partial_blockers').each do |blocker|
        next if unknown_ids.include?(blocker_key(blocker))

        lines << "  unknown blocker #{blocker['kind']}: #{blocker['reason']}"
      end
      rejections = payload.fetch('target_rejection_reasons')
      rejection_summary = payload.fetch('target_rejection_summary')
      lines << "Target rejection reasons: #{rejections.empty? ? 'none' : rejection_summary.fetch('total')}"
      rejections.each do |rejection|
        lines << "  rejected #{rejection['definition_id']} by #{rejection['producer']}: #{rejection['reason']}"
      end
    end

    def append_special_diagnostics(lines)
      matches = payload.fetch('non_ruby_matches')
      match_summary = payload.fetch('non_ruby_match_summary')
      lines << "Non-Ruby matches: #{match_summary.fetch('total')} (shown #{match_summary.fetch('returned')})"
      matches.each do |match|
        metadata = match.fetch('metadata')
        lines << "  #{metadata['file']}:#{metadata['line']} [#{metadata['match_kind']}] #{metadata['snippet']}"
      end
      failures = payload.fetch('parse_and_analyzer_failures')
      lines << "Parse failures: #{summary_count(failures, 'parse_failure_summary')}; " \
               "parse blockers=#{summary_count(failures, 'parse_blocker_summary')}; " \
               "analyzer failures=#{summary_count(failures, 'analyzer_failure_summary')}"
      failures.fetch('parse_failures').each do |failure|
        lines << "  #{failure['file']}:#{failure['line']} [#{failure['type']}] #{failure['message']}"
      end
      failures.fetch('analyzer_failures').each do |failure|
        lines << "  analyzer #{failure['source']}: #{failure['reason']}"
      end
    end

    def append_rules(lines)
      rules = payload.fetch('enabled_rules_and_types')
      analyzers = rules.fetch('analyzers').map { |profile| "#{profile['name']}(#{profile['kind']})" }
      types = rules.fetch('type_providers').map { |profile| profile['name'] }
      lines << "Enabled analyzers: #{list_or_none(analyzers)}"
      lines << "Enabled type providers: #{list_or_none(types)}"
      analyzer_summary = rules.fetch('analyzer_summary')
      type_summary = rules.fetch('type_provider_summary')
      lines << "  ... #{analyzer_summary.fetch('truncated')} analyzers omitted" if analyzer_summary.fetch('truncated').positive?
      lines << "  ... #{type_summary.fetch('truncated')} type providers omitted" if type_summary.fetch('truncated').positive?
      lines << "Assumptions: #{list_or_none(payload.fetch('assumptions'))}"
      assumption_summary = payload.fetch('assumption_summary')
      lines << "  ... #{assumption_summary.fetch('truncated')} assumptions omitted" if assumption_summary.fetch('truncated').positive?
    end

    def append_suggestions(lines)
      lines << 'Suggested next evidence:'
      payload.fetch('suggested_next_evidence').each do |suggestion|
        lines << "  #{suggestion['kind']}: #{suggestion['details']}"
      end
      summary = payload.fetch('suggested_next_evidence_summary')
      lines << "  ... #{summary.fetch('truncated')} suggestions omitted" if summary.fetch('truncated').positive?
    end

    def node_reference(node)
      "#{node['symbol_id']} [#{node['definition_id']}]"
    end

    def list_or_none(items)
      items.empty? ? 'none' : items.join(', ')
    end

    def summary_count(payload, key)
      summary = payload.fetch(key)
      "#{summary.fetch('total')} (shown #{summary.fetch('returned')})"
    end

    def unknown_blocker_keys(blockers)
      blockers.to_set { |blocker| blocker_key(blocker) }
    end

    def blocker_key(blocker)
      [blocker['kind'], blocker['scope_kind'], blocker['scope_value'], blocker['source'], blocker['reason']]
    end
  end
end
