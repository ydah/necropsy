# frozen_string_literal: true

require 'pathname'

module Necropsy
  class LoadGraph
    OBSERVATION_LIMIT = 50

    def self.record_unrooted_units(graph:, reachability:)
      reached = (reachability.runtime_alive + reachability.external_alive).to_set
      root_calls = graph.call_sites.group_by(&:caller_id)
      units = graph.nodes.values.filter_map do |node|
        next unless node.kind == :block_entry && !node.test
        next if reached.include?(node.graph_id)

        calls = root_calls.fetch(node.graph_id, [])
        next if calls.empty?

        {
          'definition_id' => node.graph_id,
          'file' => node.file,
          'top_level_calls' => calls.map(&:message).uniq.sort.first(OBSERVATION_LIMIT)
        }
      end.sort_by { |unit| unit.fetch('file') }
      graph.observation['unrooted_load_units'] = {
        'count' => units.length,
        'units' => units.first(OBSERVATION_LIMIT),
        'truncated' => units.length > OBSERVATION_LIMIT
      }
    end

    def initialize(graph:, project:)
      @graph = graph
      @project = project
      @resolved = []
      @unresolved = []
      @dynamic = []
    end

    def apply
      load_sites.each { |site| apply_site(site) }
      graph.observation['load_graph'] = observation
    end

    private

    attr_reader :graph, :project, :resolved, :unresolved, :dynamic

    def load_sites
      graph.call_sites.select { |site| site.metadata['load_reference'].is_a?(Hash) }
                      .sort_by { |site| [site.file, site.line, site.call_site_id] }
    end

    def apply_site(site)
      reference = site.metadata.fetch('load_reference')
      return apply_dynamic_site(site, reference) unless reference['literal']

      targets, strategy = resolve_literal(site, reference)
      if targets.empty?
        unresolved << site_record(site, reference).merge('reason' => 'external_or_missing')
        return
      end

      targets.each do |target|
        graph.add_edge(site.caller_id, target.graph_id, load_evidence(site, target, reference, strategy))
      end
      resolved << site_record(site, reference).merge(
        'strategy' => strategy,
        'target_files' => targets.map(&:file).sort
      )
    end

    def apply_dynamic_site(site, reference)
      targets = site.test ? file_roots : file_roots.reject(&:test)
      targets.each do |target|
        graph.add_edge(site.caller_id, target.graph_id, load_evidence(site, target, reference, 'dynamic_conservative'))
      end
      graph.add_blocker(dynamic_load_blocker(site, reference))
      dynamic << site_record(site, reference).merge('candidate_load_units' => targets.length)
    end

    def resolve_literal(site, reference)
      path = reference.fetch('path')
      if reference.fetch('kind') == 'require_relative'
        candidates = relative_candidates(File.dirname(site.file), path)
        return [roots_for(candidates), 'require_relative']
      end

      candidates = require_candidates(path)
      [roots_for(candidates), reference.fetch('kind') == 'autoload' ? 'autoload_lib_path' : 'require_lib_path']
    end

    def relative_candidates(base, path)
      normalized = safe_relative_path(File.join(base, path))
      source_candidates(normalized)
    end

    def require_candidates(path)
      normalized = safe_relative_path(path)
      return [] unless normalized

      explicit = normalized.start_with?('lib/') ? source_candidates(normalized) : []
      (explicit + source_candidates(File.join('lib', normalized))).uniq
    end

    def source_candidates(path)
      return [] unless path

      File.extname(path).empty? ? [path, "#{path}.rb"] : [path]
    end

    def safe_relative_path(path)
      return if Pathname.new(path).absolute?

      cleaned = Pathname.new(path).cleanpath.to_s
      return if cleaned == '..' || cleaned.start_with?('../')

      cleaned.delete_prefix('./')
    rescue ArgumentError
      nil
    end

    def roots_for(paths)
      paths.filter_map { |path| file_roots_by_path[path] }.uniq(&:graph_id).sort_by(&:graph_id)
    end

    def file_roots
      @file_roots ||= graph.nodes.values.select { |node| node.kind == :block_entry }.sort_by(&:graph_id)
    end

    def file_roots_by_path
      @file_roots_by_path ||= file_roots.to_h { |node| [node.file, node] }
    end

    def load_evidence(site, target, reference, strategy)
      exact = strategy == 'require_relative'
      Evidence.new(
        analyzer: :load_graph,
        kind: :load_edge,
        weight: exact ? 1.0 : 0.7,
        details: "#{reference.fetch('kind')} loads #{target.file}",
        metadata: {
          'call_site_id' => site.call_site_id,
          'load_kind' => reference.fetch('kind'),
          'strategy' => strategy,
          'target_definition_id' => target.graph_id
        },
        producer: :load_graph,
        producer_version: Necropsy::VERSION,
        grade: exact ? :exact : :conservative,
        relation: :load_edge,
        source: { 'call_site_id' => site.call_site_id, 'file' => site.file, 'line' => site.line },
        assumptions: exact ? [] : [load_assumption(strategy)],
        scope: { 'caller_definition_id' => site.caller_id, 'target_definition_id' => target.graph_id }
      )
    end

    def load_assumption(strategy)
      return 'dynamic_load_may_select_any_scanned_load_unit' if strategy == 'dynamic_conservative'

      'lib_is_on_the_ruby_load_path'
    end

    def dynamic_load_blocker(site, reference)
      Blocker.new(
        kind: :dynamic_load,
        scope_kind: :definition,
        scope_value: site.caller_id,
        source: :load_graph,
        reason: "#{reference.fetch('kind')} path is not a static string or symbol",
        suggested_action: :make_load_path_literal,
        metadata: {
          'caller_domain' => site.test ? 'test' : 'runtime',
          'caller_id' => site.caller_id,
          'call_site_id' => site.call_site_id,
          'file' => site.file,
          'line' => site.line,
          'load_kind' => reference.fetch('kind')
        }
      )
    end

    def site_record(site, reference)
      {
        'call_site_id' => site.call_site_id,
        'caller_definition_id' => site.caller_id,
        'file' => site.file,
        'line' => site.line,
        'kind' => reference.fetch('kind'),
        'path' => reference['path']
      }.compact
    end

    def observation
      {
        'resolved_count' => resolved.length,
        'unresolved_literal_count' => unresolved.length,
        'dynamic_count' => dynamic.length,
        'resolved' => resolved.first(OBSERVATION_LIMIT),
        'unresolved_literals' => unresolved.first(OBSERVATION_LIMIT),
        'dynamic' => dynamic.first(OBSERVATION_LIMIT)
      }
    end
  end
end
