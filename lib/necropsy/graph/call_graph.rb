# frozen_string_literal: true

module Necropsy
  class CallGraph
    attr_reader :nodes, :call_sites, :instantiated_classes, :entry_points, :profiles, :observation, :class_infos,
                :entrypoint_hints

    def initialize(scan_result)
      @nodes = {}
      @edges = {}
      @incoming_edges = {}
      @call_sites = scan_result.call_sites
      @instantiated_classes = scan_result.instantiated_classes.dup
      @class_infos = scan_result.class_infos.to_h { |info| [info.id, info] }
      @entrypoint_hints = scan_result.entrypoint_hints
      @entry_points = []
      @profiles = []
      @uncertainties = scan_result.uncertainties.to_h do |node_id, messages|
        [node_id, Array(messages).dup]
      end
      @dynamic_alive = {}
      @observation = {}
      @descendants = {}
      scan_result.nodes.each { |node| add_node(node) }
      retain_known_instantiated_classes
    end

    def add_node(node)
      nodes[node.id] ||= node
    end

    def add_entry_point(node_id, reason)
      return unless nodes.key?(node_id)

      entry = EntryPoint.new(node_id: node_id, reason: reason)
      entry_points << entry unless entry_points.include?(entry)
    end

    def apply_result(result)
      result.edge_evidences.each { |edge| add_edge(edge.caller_id, edge.callee_id, edge.evidence) }
      matched_alive = result.alive_evidences.count { |alive| add_alive(alive.node_id, alive.evidence) }
      warn_unmatched_dynamic_evidence(result.alive_evidences.length) if matched_alive.zero?
      result.uncertainties.each do |node_id, messages|
        @uncertainties[node_id] ||= []
        @uncertainties[node_id].concat(Array(messages))
      end
      observation.merge!(result.observation) { |_key, left, right| merge_observation(left, right) }
    end

    def add_profile(profile)
      profiles << profile
    end

    def add_edge(caller_id, callee_id, evidence)
      return unless nodes.key?(caller_id) && nodes.key?(callee_id)

      @edges[caller_id] ||= {}
      @edges[caller_id][callee_id] ||= []
      @edges[caller_id][callee_id] << evidence
      @incoming_edges[callee_id] ||= {}
      @incoming_edges[callee_id][caller_id] = @edges[caller_id][callee_id]
    end

    def add_alive(node_id, evidence)
      return false unless nodes.key?(node_id)

      @dynamic_alive[node_id] ||= []
      @dynamic_alive[node_id] << evidence
      true
    end

    def dynamic_alive?(node_id)
      @dynamic_alive.key?(node_id)
    end

    def alive_evidences(node_id)
      @dynamic_alive[node_id] || []
    end

    def dynamic_enabled?
      @dynamic_alive.any?
    end

    def edges_from(node_id)
      @edges.fetch(node_id, {})
    end

    def edges
      @edges.flat_map do |caller_id, callees|
        callees.map do |callee_id, evidences|
          Edge.new(caller_id: caller_id, callee_id: callee_id, evidences: evidences)
        end
      end
    end

    def incoming_edges(node_id)
      @incoming_edges.fetch(node_id, {}).map do |caller_id, evidences|
        Edge.new(caller_id: caller_id, callee_id: node_id, evidences: evidences)
      end
    end

    def uncertainties(node_id = nil)
      return @uncertainties unless node_id

      @uncertainties.fetch(node_id, [])
    end

    def method_nodes
      nodes.values.select(&:method?)
    end

    def class_info(owner)
      class_infos[owner]
    end

    def descendants_of(owner)
      @descendants[owner] ||= class_infos.keys.select do |candidate|
        candidate == owner || ancestor_chain(candidate).include?(owner)
      end
    end

    def modules_for(owner)
      info = class_info(owner)
      return [] unless info

      (info.prepends + info.includes + info.extends).uniq
    end

    def candidate_nodes(message)
      method_nodes.select { |node| node.name == message }
    end

    def resolve_call_site(site, rta: false)
      candidates = rta ? rta_candidates_for_receiver(site) : candidates_for_receiver(site)
      candidates = candidates.select { |node| rta_candidate?(node, site) } if rta
      candidates
    end

    def retain_rta_candidates(candidates, site)
      candidates.select { |node| rta_candidate?(node, site) }
    end

    def reconcile_rta_result(result)
      analyzed_sites = result.observation.dig('rta', 'analyzed_sites')
      return unless analyzed_sites

      analyzed_keys = analyzed_sites.to_set { |site| call_site_key(site) }
      allowed = result.edge_evidences.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |edge, memo|
        memo[call_site_key(edge.evidence.metadata)] << edge.callee_id
      end

      @edges.each_value do |callees|
        callees.each do |callee_id, evidences|
          evidences.reject! do |item|
            next false unless %i[name_resolution cha].include?(item.analyzer)

            key = call_site_key(item.metadata)
            analyzed_keys.include?(key) && !allowed[key].include?(callee_id)
          end
        end
        callees.delete_if { |_callee_id, evidences| evidences.empty? }
      end
      @edges.delete_if { |_caller_id, callees| callees.empty? }
      rebuild_incoming_edges
    end

    def fallback_resolution?(site)
      resolved = resolve_call_site(site)
      return false if resolved.empty?

      case site.receiver_kind
      when :constant
        receiver_candidates(site).none? { |name| nodes.key?("#{name}.#{site.message}") }
      when :instance
        receiver_candidates(site).none? { |name| nodes.key?("#{name}##{site.message}") }
      when :implicit
        same_owner_candidates(site).empty?
      when :unknown
        true
      else
        false
      end
    end

    def to_h
      {
        'nodes' => nodes.values.map(&:to_h),
        'edges' => edges.map(&:to_h),
        'entry_points' => entry_points.map(&:to_h),
        'class_infos' => class_infos.values.map(&:to_h),
        'instantiated_classes' => instantiated_classes.to_a.sort,
        'profiles' => profiles.map(&:to_h),
        'observation' => observation
      }
    end

    private

    def candidates_for_receiver(site)
      case site.receiver_kind
      when :constant
        exact = receiver_candidates(site).filter_map { |name| nodes["#{name}.#{site.message}"] }.first
        exact ? [exact] : unique_fallback_candidate(site.message)
      when :instance
        exact = receiver_candidates(site).filter_map { |name| nodes["#{name}##{site.message}"] }.first
        exact ? [exact] : unique_fallback_candidate(site.message)
      when :self
        same_owner_candidates(site)
      when :super
        super_candidates(site)
      when :implicit
        same_owner_candidates(site).then do |matches|
          matches.empty? ? unique_fallback_candidate(site.message) : matches
        end
      else
        unique_fallback_candidate(site.message)
      end
    end

    def rta_candidates_for_receiver(site)
      exact = candidates_for_receiver(site)
      return exact unless exact.empty?

      candidate_nodes(site.message)
    end

    def same_owner_candidates(site)
      caller = nodes[site.caller_id]
      return [] unless caller&.owner

      ids = [
        "#{caller.owner}##{site.message}",
        "#{caller.owner}.#{site.message}"
      ]
      ids.filter_map { |id| nodes[id] }
    end

    def super_candidates(site)
      caller = nodes[site.caller_id]
      return [] unless caller&.owner

      separator = caller.kind == :singleton_method ? '.' : '#'
      owner = class_info(caller.owner)&.superclass
      while owner
        candidate = nodes["#{owner}#{separator}#{site.message}"]
        return [candidate] if candidate

        owner = class_info(owner)&.superclass
      end
      []
    end

    def receiver_candidates(site)
      candidates = site.metadata['receiver_candidates'] || site.metadata[:receiver_candidates]
      Array(candidates).compact.empty? ? [site.receiver_name].compact : Array(candidates).compact
    end

    def unique_fallback_candidate(message)
      candidates = candidate_nodes(message)
      candidates.one? ? candidates : []
    end

    def rta_candidate?(node, site)
      return true unless node.kind == :instance_method

      caller_owner = nodes[site.caller_id]&.owner
      return true if site.receiver_kind == :super
      return dispatched_instance_owner(caller_owner, site.message) == node.owner if %i[self implicit].include?(site.receiver_kind)

      return true if node.owner == caller_owner
      return true if class_info(node.owner)&.dynamic

      instantiated_classes.any? { |owner| dispatched_instance_owner(owner, site.message) == node.owner }
    end

    def dispatched_instance_owner(owner, message)
      method_lookup_chain(owner).find { |candidate| nodes.key?("#{candidate}##{message}") }
    end

    def method_lookup_chain(owner, seen = Set.new)
      return [] unless owner && seen.add?(owner)

      info = class_info(owner)
      return [owner] unless info

      prepends = info.prepends.reverse.flat_map { |name| method_lookup_chain(name, seen) }
      includes = info.includes.reverse.flat_map { |name| method_lookup_chain(name, seen) }
      prepends + [owner] + includes + method_lookup_chain(info.superclass, seen)
    end

    def ancestor_chain(owner)
      chain = []
      current = class_info(owner)&.superclass
      while current && !chain.include?(current)
        chain << current
        current = class_info(current)&.superclass
      end
      chain
    end

    def merge_observation(left, right)
      return right unless left.is_a?(Hash) && right.is_a?(Hash)

      left.merge(right)
    end

    def call_site_key(site)
      metadata = site['metadata'] || site[:metadata] || {}
      [
        site['caller_id'] || site[:caller_id],
        site['message'] || site[:message],
        (site['receiver_kind'] || site[:receiver_kind])&.to_s,
        site['receiver_name'] || site[:receiver_name],
        site['file'] || site[:file],
        site['line'] || site[:line],
        Array(metadata['receiver_candidates'] || metadata[:receiver_candidates]).sort,
        metadata['implicit_from'] || metadata[:implicit_from]
      ]
    end

    def rebuild_incoming_edges
      @incoming_edges = {}
      @edges.each do |caller_id, callees|
        callees.each do |callee_id, evidences|
          @incoming_edges[callee_id] ||= {}
          @incoming_edges[callee_id][caller_id] = evidences
        end
      end
    end

    def retain_known_instantiated_classes
      known_owners = method_nodes.map(&:owner).compact.to_set
      instantiated_classes.select! { |name| known_owners.include?(name) }
    end

    def warn_unmatched_dynamic_evidence(attempted)
      return if attempted.zero?

      warn "Necropsy ignored #{attempted} dynamic node IDs because none matched the scanned project; " \
           'dynamic absence will not be used for unused classification.'
    end
  end
end
