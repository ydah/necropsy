# frozen_string_literal: true

module Necropsy
  class CallGraph
    include DynamicEvidenceTracking
    include BlockerMatching

    attr_reader :store, :call_sites, :instantiated_classes, :observation, :class_infos,
                :entrypoint_hints, :ambiguity_limit, :file_statuses, :source_errors, :source_domains,
                :scope_diagnostics, :method_signatures

    def nodes
      store.nodes
    end

    def entry_points
      store.entry_points
    end

    def profiles
      store.profiles
    end

    def evidence_records
      evidence_ledger.evidence_records
    end

    def evidence_record(evidence_id)
      evidence_ledger.evidence_record(evidence_id)
    end

    def evidence_collisions
      evidence_ledger.evidence_collisions
    end

    def resolution_records(call_site_id = nil)
      resolution_ledger.resolution_records(call_site_id)
    end

    def resolution_status_counts
      resolution_ledger.resolution_status_counts
    end

    def call_sites_resolving_definition(definition_id)
      resolution_ledger.call_sites_resolving_definition(definition_id)
    end

    def resolution_conflicts
      resolution_ledger.resolution_conflicts
    end

    def resolution_issues
      resolution_ledger.resolution_issues
    end

    def initialize(scan_result, ambiguity_limit: 4)
      @store = Graph::Store.new(uncertainties: scan_result.uncertainties)
      @call_sites = scan_result.call_sites
      @instantiated_classes = scan_result.instantiated_classes.dup
      @class_infos = scan_result.class_infos.to_h { |info| [info.id, info] }
      @direct_subclasses = Hash.new { |hash, key| hash[key] = [] }
      @class_infos.each_value do |info|
        @direct_subclasses[info.superclass] << info.id if info.superclass
      end
      @direct_subclasses.each_value(&:sort!)
      @entrypoint_hints = scan_result.entrypoint_hints
      @file_statuses = scan_result.file_statuses.to_h do |file, status|
        [file.to_s, status.to_sym]
      end
      @source_errors = scan_result.source_errors.dup
      @source_domains = scan_result.source_domains.to_h do |file, domain|
        [file.to_s, domain.to_sym]
      end
      @scope_diagnostics = scan_result.scope_diagnostics.dup
      @method_signatures = scan_result.method_signatures.dup
      @ambiguity_limit = ambiguity_limit
      @blockers = []
      initialize_blocker_indexes
      @observation = {}
      record_generated_macro_observation(scan_result.nodes)
      @resolution_ledger = Graph::ResolutionLedger.new(self)
      @descendants = {}
      @rta_instantiated_owner_cache = {}
      @duplicate_blockers_initialized = false
      scan_result.nodes.each { |node| add_node(node) }
      register_duplicate_definition_blockers
      @duplicate_blockers_initialized = true
      register_incomplete_source_blockers
      scan_result.semantic_blockers.each { |blocker| add_blocker(blocker) }
      retain_known_instantiated_classes
      @evidence_ledger = Graph::EvidenceLedger.new(self)
    end

    def add_node(node)
      existing = nodes.exact(node.graph_id)
      return existing if existing

      @method_nodes = nil
      @nodes_by_name = nil
      @runtime_nodes_by_name = nil
      @dispatch_cache = nil
      @lookup_chain_cache = nil
      @singleton_lookup_chain_cache = nil
      @owner_ancestor_cache = nil
      @flow_lookup_cache = nil
      @rta_instantiated_owner_cache = {}
      @dynamic_ancestry_cache = {}
      added = nodes.add(node)
      register_duplicate_definition_blocker(node.symbol_id) if @duplicate_blockers_initialized
      refresh_resolution_derived_state
      added
    end

    def record_generated_macro_observation(scanned_nodes)
      groups = scanned_nodes.select { |node| node.defined_via.to_s.start_with?('rails_') }.group_by do |node|
        [node.file, node.line, node.owner, node.defined_via.to_s]
      end
      return if groups.empty?

      observation['rails_generated_macros'] = {
        'count' => groups.length,
        'generated_method_count' => groups.values.sum(&:length),
        'macros' => groups.sort_by(&:first).map do |(file, line, owner, macro), nodes|
          {
            'file' => file,
            'line' => line,
            'owner' => owner,
            'macro' => macro.delete_prefix('rails_'),
            'generated_methods' => nodes.map(&:name).uniq.sort
          }
        end
      }
    end
    private :record_generated_macro_observation

    def add_entry_point(node_id, reason, domain: nil, evidence: nil)
      resolve_definitions(node_id).each do |definition|
        entry = Root.new(
          definition_id: definition.graph_id,
          domain: domain,
          reason: reason,
          evidence: evidence
        )
        entry_points << entry unless entry_points.include?(entry)
      end
    end

    def definitions_for(symbol_id)
      nodes.definitions_for(symbol_id)
    end

    def call_sites_for_message(message)
      @call_sites_by_message ||= call_sites.group_by { |site| site.message.to_s }.transform_values(&:freeze).freeze
      @call_sites_by_message.fetch(message.to_s, [])
    end

    def apply_result(result, refresh: true)
      Graph::Transaction.apply(self, result, refresh: refresh)
    end

    def apply_result!(result, refresh: true)
      register_result_call_sites(result)
      dynamic_result = dynamic_result?(result)
      edge_matches = result.edge_evidences.map do |edge|
        next apply_dynamic_edge(edge) if dynamic_result

        add_edge(edge.caller_id, edge.callee_id, edge.evidence)
      end
      alive_matches = result.alive_evidences.map do |alive|
        dynamic_result ? apply_dynamic_alive(alive.node_id, alive.evidence) : add_alive(alive.node_id, alive.evidence)
      end
      register_result_evidences(result)
      result.uncertainties.each do |node_id, messages|
        resolved_ids = resolve_definitions(node_id).map(&:graph_id)
        resolved_ids = [node_id] if resolved_ids.empty?
        resolved_ids.each do |resolved_id|
          store.uncertainties[resolved_id] ||= []
          store.uncertainties[resolved_id].concat(Array(messages))
        end
      end
      Array(result.respond_to?(:blockers) ? result.blockers : []).each { |blocker| add_blocker(blocker) }
      observation.merge!(result.observation) { |_key, left, right| merge_observation(left, right) }
      record_dynamic_evidence(result, alive_matches, edge_matches) if dynamic_result
      register_result_resolutions(result, refresh: refresh)
      refresh_resolution_derived_state if refresh && (!result.respond_to?(:resolutions) || result.resolutions.nil?)
    end
    private :apply_result!

    def refresh_derived_state
      refresh_resolution_derived_state
    end

    def add_profile(profile)
      profiles << profile
    end

    def add_edge(caller_id, callee_id, evidence)
      callers = resolve_definitions(caller_id)
      callees = resolve_definitions(callee_id)
      if callers.empty? || callees.empty?
        domain = callers.any? && callers.all?(&:test) ? :test : :runtime
        register_evidence(evidence, domain: domain)
        return false
      end

      record_ambiguous_input(:edge_caller, caller_id, callers)
      record_ambiguous_input(:edge_callee, callee_id, callees)
      callers.product(callees).each do |caller, callee|
        add_physical_edge(caller.graph_id, callee.graph_id, evidence)
      end
      true
    end

    def add_alive(node_id, evidence)
      definitions = resolve_definitions(node_id)
      if definitions.empty?
        register_evidence(evidence)
        return false
      end

      record_ambiguous_input(:alive, node_id, definitions)
      definitions.each do |definition|
        evidence_id = register_evidence(evidence, domain: definition.test ? :test : :runtime)
        next unless evidence_id

        store.dynamic_alive[definition.graph_id] ||= Set.new
        store.dynamic_alive[definition.graph_id] << evidence_id
      end
      true
    end

    def dynamic_alive?(node_id)
      resolve_definitions(node_id).any? do |definition|
        store.dynamic_alive.fetch(definition.graph_id, Set.new).any? { |evidence_id| evidence_record(evidence_id) }
      end
    end

    def alive_evidences(node_id, projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      evidence_ids = resolve_definitions(node_id).flat_map do |definition|
        store.dynamic_alive.fetch(definition.graph_id, Set.new).to_a
      end
      projected_evidence_records(evidence_ids.uniq, projection: projection, scope: scope)
    end

    def dynamic_enabled?
      store.dynamic_alive.any?
    end

    def runtime_feedback(observed_targets:, max_fixtures: RuntimeFeedback::DEFAULT_FIXTURE_LIMIT)
      RuntimeFeedback.from_graph(
        self,
        observed_targets: observed_targets,
        max_fixtures: max_fixtures
      ).call
    end

    def performance_counts
      {
        'definitions' => nodes.length,
        'call_sites' => call_sites.length,
        'edges' => edges.length,
        'blockers' => blockers.length,
        'resolution_cache_hits' => @resolution_cache_hits.to_i,
        'resolution_cache_misses' => @resolution_cache_misses.to_i
      }
    end

    def edges_from(node_id, projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      evidence_ids_by_callee = resolve_definitions(node_id).each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |definition, merged|
        store.physical_edges.fetch(definition.graph_id, {}).each do |callee_id, evidence_ids|
          merged[callee_id].merge(evidence_ids)
        end
      end
      evidence_ids_by_callee.each_with_object({}) do |(callee_id, evidence_ids), projected|
        records = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
        projected[callee_id] = records unless records.empty?
      end
    end

    def edge_present?(caller_id, callee_id)
      store.physical_edges.dig(caller_id, callee_id)&.any? { |evidence_id| evidence_record(evidence_id) }
    end

    def edges(projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      store.physical_edges.flat_map do |caller_id, callees|
        callees.filter_map do |callee_id, evidence_ids|
          evidences = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
          Edge.new(caller_id: caller_id, callee_id: callee_id, evidences: evidences) unless evidences.empty?
        end
      end.sort_by { |edge| [edge.caller_id, edge.callee_id] }
    end

    def edge_relations(projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      store.physical_edges.flat_map do |caller_id, callees|
        callees.filter_map do |callee_id, evidence_ids|
          projected_ids = projected_evidence_ids(evidence_ids, projection: projection, scope: scope)
          next if projected_ids.empty?

          EdgeRelation.new(
            caller_id: caller_id,
            callee_id: callee_id,
            evidence_ids: projected_ids,
            projection: projection
          )
        end
      end.sort_by { |edge| [edge.caller_id, edge.callee_id] }
    end

    def incoming_edges(node_id, projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      resolve_definitions(node_id).flat_map do |definition|
        store.incoming_edges.fetch(definition.graph_id, {}).filter_map do |caller_id, evidence_ids|
          evidences = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
          Edge.new(caller_id: caller_id, callee_id: definition.graph_id, evidences: evidences) unless evidences.empty?
        end
      end.sort_by { |edge| [edge.caller_id, edge.callee_id] }
    end

    def uncertainties(node_id = nil)
      return store.uncertainties unless node_id

      resolved = resolve_definitions(node_id)
      return store.uncertainties.fetch(node_id, []) if resolved.empty?

      resolved.flat_map { |definition| store.uncertainties.fetch(definition.graph_id, []) }.uniq
    end

    def incomplete_files
      file_statuses.filter_map { |file, status| file unless status == :complete }.sort
    end

    def analyze_source?(file)
      source_domains.fetch(file.to_s, :analyze) == :analyze
    end

    def source_incompleteness
      {
        'incomplete_files' => incomplete_files.length,
        'files' => incomplete_files.map do |file|
          {
            'file' => file,
            'status' => file_statuses.fetch(file).to_s,
            'errors' => source_errors.select { |error| error.file == file }.map(&:to_h)
          }
        end
      }
    end

    def method_nodes
      @method_nodes ||= nodes.values.select(&:method?)
    end

    def nodes_by_name
      @nodes_by_name ||= method_nodes.group_by(&:name).freeze
    end

    def class_info(owner)
      class_infos[owner]
    end

    def descendants_of(owner)
      @descendants[owner] ||= begin
        descendants = []
        queue = class_infos.key?(owner) ? [owner] : []
        seen = Set.new
        head = 0
        while head < queue.length
          candidate = queue.fetch(head)
          head += 1
          next unless seen.add?(candidate)

          descendants << candidate
          queue.concat(@direct_subclasses.fetch(candidate, []))
        end
        descendants.freeze
      end
    end

    def modules_for(owner)
      info = class_info(owner)
      return [] unless info

      (info.prepends + info.includes + info.extends).uniq
    end

    def candidate_nodes(message, domain: nil)
      index = domain&.to_sym == :runtime ? runtime_nodes_by_name : nodes_by_name
      index.fetch(message, [])
    end

    def ambiguous_fallback_candidates(message, domain: nil)
      candidates = candidate_nodes(message, domain: domain)
      return candidates if candidates.one?
      return [] if candidates.size > @ambiguity_limit

      candidates
    end

    def ambiguity_exceeded?(message, domain: nil)
      candidate_nodes(message, domain: domain).size > ambiguity_limit
    end

    def ambiguous_resolution?
      @ambiguity_limit > 1
    end

    def owner_reachable_from_ancestor?(owner, ancestor)
      @owner_ancestor_cache ||= {}
      key = [owner, ancestor]
      return @owner_ancestor_cache[key] if @owner_ancestor_cache.key?(key)

      @owner_ancestor_cache[key] = descendants_of(ancestor).any? do |descendant|
        cached_lookup_chain(descendant).include?(owner)
      end
    end

    def resolve_call_site(site, rta: false)
      candidates = rta ? rta_candidates_for_receiver(site) : method_lookup(site).targets
      candidates = candidates.select { |node| rta_candidate?(node, site) } if rta
      candidates
    end

    def cha_method_lookup(site)
      primary = method_lookup(site)
      return primary if primary.complete?

      lookups = case site.receiver_kind
                when :constant
                  receiver_candidates(site).map { |owner| canonical_receiver_lookup(site, owner, :constant) }
                when :instance
                  receiver_candidates(site).flat_map do |owner|
                    descendants_of(owner).map { |candidate| canonical_receiver_lookup(site, candidate, :instance) }
                  end
                else
                  []
                end
      targets = [primary, *lookups].flat_map(&:targets).uniq(&:graph_id).sort_by(&:graph_id)
      chain = [primary, *lookups].flat_map(&:lookup_chain).uniq
      incomplete_method_lookup(targets, chain, 'cha_canonical_lookup')
    end

    def residual_scope_for(site)
      return UnknownScope.new(scope_kind: :message, scope_value: site.message, match: :exact) if site.receiver_kind == :unknown

      owners = receiver_candidates(site)
      owners = [nodes.exact(site.caller_id)&.owner].compact if owners.empty?
      return UnknownScope.new(scope_kind: :message, scope_value: site.message, match: :exact) if owners.empty?

      UnknownScope.new(scope_kind: :owner, scope_value: owners.sort, match: :exact)
    end

    def method_lookup(site)
      return fallback_method_lookup(site, reason: 'dynamic_message') if site.dynamic
      return physical_target_lookup(site) if physical_target_id(site)
      return unproven_initialize_lookup(site) if unproven_initialize_dispatch?(site)
      return callable_method_lookup(site) if flow_callable?(site)
      return flow_instance_method_lookup(site) if flow_instance_types(site)
      return incomplete_method_lookup([], [], 'flow_unknown_receiver') if site.metadata['flow_unknown_receiver']

      case site.receiver_kind
      when :constant
        owner = resolved_receiver_owner(site)
        ordered_method_lookup(
          site,
          singleton_lookup_entries(owner),
          reason: 'singleton_lookup',
          completeness_entries: [[owner, '.']]
        )
      when :instance
        owner = resolved_receiver_owner(site)
        ordered_method_lookup(
          site,
          instance_lookup_entries(owner),
          reason: 'instance_lookup',
          completeness_entries: [[owner, '#']]
        )
      when :self, :implicit
        self_method_lookup(site)
      when :super
        super_method_lookup(site)
      else
        fallback_method_lookup(site, reason: 'unknown_receiver')
      end
    end

    def flow_instance_method_lookup(site)
      @flow_lookup_cache ||= {}
      cache_key = [site.call_site_id, flow_instance_types(site)]
      return @flow_lookup_cache[cache_key] if @flow_lookup_cache.key?(cache_key)

      results = flow_instance_types(site).map do |owner|
        ordered_method_lookup(
          site,
          instance_lookup_entries(owner),
          reason: 'flow_instance_lookup',
          completeness_entries: [[owner, '#']]
        )
      end
      result = results.first if results.one?
      return @flow_lookup_cache[cache_key] = result if result

      @flow_lookup_cache[cache_key] = merge_flow_method_lookups(results)
    end

    def physical_target_id(site)
      hash_value(site.metadata, 'physical_target_definition_id')
    end

    def physical_target_lookup(site)
      target = nodes.exact(physical_target_id(site).to_s)
      return incomplete_method_lookup([], [], 'physical_target_missing') unless target

      MethodLookup.new(
        targets: [target],
        status: :complete,
        lookup_chain: [target.owner],
        reason: 'physical_definition_relation'
      )
    end

    def merge_flow_method_lookups(results)
      targets = results.flat_map(&:targets).uniq(&:graph_id).sort_by(&:graph_id)
      chain = results.flat_map(&:lookup_chain).uniq
      return incomplete_method_lookup(targets, chain, 'flow_instance_lookup_incomplete') unless results.all?(&:complete?)

      accepted_ids = targets.to_set(&:graph_id)
      rejections = results.flat_map(&:rejected_targets).reject do |rejection|
        accepted_ids.include?(rejection.definition_id)
      end.uniq { |rejection| [rejection.definition_id, rejection.reason] }
      MethodLookup.new(
        targets: targets,
        status: :complete,
        rejected_targets: rejections,
        lookup_chain: chain,
        reason: 'flow_instance_lookup'
      )
    end

    def flow_instance_types(site)
      fact = site.metadata['receiver_value_fact'] || site.metadata[:receiver_value_fact]
      return nil unless fact.is_a?(Hash)
      return nil unless hash_value(fact, 'kind').to_s == 'instance_types'
      return nil unless hash_value(fact, 'exact')

      values = Array(hash_value(fact, 'values')).map(&:to_s).reject(&:empty?).uniq.sort
      return nil if values.empty?
      return nil unless values.all? { |owner| constructor_dispatch_exact?(owner, site) }

      values
    end

    def unproven_initialize_dispatch?(site)
      metadata = site.metadata
      return false unless hash_value(metadata, 'implicit_from').to_s == 'new'

      !constructor_dispatch_exact?(resolved_receiver_owner(site), site)
    end

    def unproven_initialize_lookup(site)
      owner = resolved_receiver_owner(site)
      incomplete_method_lookup([], instance_lookup_entries(owner), 'constructor_dispatch_unproven')
    end

    def constructor_dispatch_exact?(owner, site)
      info = class_info(owner)
      return false unless info && !info.dynamic
      return false if dynamic_ancestry_uncertain?(site)

      entries = singleton_lookup_entries(owner)
      return false if dynamic_lookup_chain?(entries)
      return false if entries.any? { |candidate, separator| definitions_for("#{candidate}#{separator}new").any? }

      !constructor_mutation_blocker?(owner, entries, site)
    end

    def constructor_mutation_blocker?(owner, entries, site)
      owners = [owner, *entries.map(&:first)].to_set
      @blockers.any? do |blocker|
        next false unless %i[dynamic_ancestry unsupported_refinement variable_eval].include?(blocker.kind)
        next false unless blocker.caller_domain == :runtime || site.test

        blocker.scope_kind == :global || (blocker.scope_kind == :owner && owners.include?(blocker.scope_value))
      end
    end

    def flow_callable?(site)
      fact = site.metadata['receiver_value_fact'] || site.metadata[:receiver_value_fact]
      fact.is_a?(Hash) && hash_value(fact, 'kind').to_s == 'callable_set' && hash_value(fact, 'exact') == true
    end

    def callable_method_lookup(site)
      fact = site.metadata['receiver_value_fact'] || site.metadata[:receiver_value_fact]
      return incomplete_method_lookup([], [], 'callable_invocation_unknown') unless fact.is_a?(Hash)

      summary = hash_value(fact, 'summary') || {}
      return literal_callable_lookup unless hash_value(summary, 'reflection_kind')

      names = Array(hash_value(fact, 'values')).map(&:to_s).reject(&:empty?).uniq
      return incomplete_method_lookup([], [], 'callable_invocation_dynamic_name') if names.empty?

      caller = nodes.exact(site.caller_id)
      receiver_kind = hash_value(summary, 'receiver_kind').to_s
      receiver_values = Array(hash_value(summary, 'receiver_values')).map(&:to_s)
      separators = callable_separators(caller, receiver_kind)
      targets = names.flat_map do |name|
        owners = receiver_values.empty? ? [caller&.owner].compact : receiver_values
        owners.flat_map { |owner| separators.flat_map { |separator| definitions_for("#{owner}#{separator}#{name}") } }
      end.uniq(&:graph_id)
      return incomplete_method_lookup([], [], 'callable_invocation_missing') if targets.empty?

      MethodLookup.new(
        targets: targets.sort_by(&:graph_id),
        status: targets.length == names.length ? :complete : :partial,
        lookup_chain: targets.map(&:owner).uniq,
        reason: 'callable_invocation'
      )
    end

    def literal_callable_lookup
      incomplete_method_lookup([], [], 'literal_callable_invocation')
    end

    def callable_separators(caller, receiver_kind)
      return ['.'] if receiver_kind == 'constant'
      return ['#'] if receiver_kind == 'instance'

      [caller&.kind == :singleton_method ? '.' : '#']
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

      store.physical_edges.each_value do |callees|
        callees.each do |callee_id, evidence_ids|
          evidence_ids.delete_if do |evidence_id|
            item = evidence_record(evidence_id)
            next false unless item

            producer = item.producer || item.analyzer
            next false unless %w[name_resolution cha].include?(producer.to_s)

            key = call_site_key(item.metadata)
            analyzed_keys.include?(key) && !allowed[key].include?(callee_id)
          end
        end
        callees.delete_if { |_callee_id, evidence_ids| evidence_ids.empty? }
      end
      store.physical_edges.delete_if { |_caller_id, callees| callees.empty? }
      rebuild_incoming_edges
      refresh_resolution_derived_state
    end

    def fallback_resolution?(site, resolved: nil)
      resolved ||= resolve_call_site(site)
      return false if resolved.empty?

      lookup = method_lookup(site)
      domain = site.test ? :test : :runtime
      fallback = ambiguous_fallback_candidates(site.message, domain: domain)
      !lookup.complete? && resolved.map(&:graph_id).sort == fallback.map(&:graph_id).sort
    end

    def to_h
      {
        'nodes' => nodes.values.map(&:to_h),
        'call_sites' => call_sites.map(&:to_h),
        'edges' => edges.map(&:to_h),
        'edge_projection' => 'conservative',
        'edge_relations' => edge_relations.map(&:to_h),
        'evidence_records' => evidence_records.map(&:to_h),
        'evidence_collisions' => evidence_collisions,
        'entry_points' => entry_points.map(&:to_h),
        'class_infos' => class_infos.values.map(&:to_h),
        'instantiated_classes' => instantiated_classes.to_a.sort,
        'profiles' => profiles.map(&:to_h),
        'resolutions' => resolution_records.map(&:to_h),
        'resolution_conflicts' => resolution_conflicts,
        'blockers' => blockers.map(&:to_h),
        'file_statuses' => file_statuses.transform_values(&:to_s),
        'source_errors' => source_errors.map(&:to_h),
        'source_domains' => source_domains.transform_values(&:to_s),
        'scope_diagnostics' => scope_diagnostics,
        'observation' => observation
      }
    end

    private

    attr_reader :evidence_ledger, :resolution_ledger

    def register_result_resolutions(result, refresh: true)
      resolution_ledger.register_result_resolutions(result, refresh: refresh)
    end

    def refresh_resolution_derived_state
      resolution_ledger.refresh_resolution_derived_state
    end

    def canonical_payload(value)
      resolution_ledger.send(:canonical_payload, value)
    end

    def normalize_projection(projection)
      evidence_ledger.normalize_projection(projection)
    end

    def projected_evidence_records(evidence_ids, projection:, scope: nil)
      evidence_ledger.projected_evidence_records(evidence_ids, projection: projection, scope: scope)
    end

    def projected_evidence_ids(evidence_ids, projection:, scope: nil)
      evidence_ledger.projected_evidence_ids(evidence_ids, projection: projection, scope: scope)
    end

    def register_evidence(evidence, domain: :runtime, canonical_payload: nil)
      evidence_ledger.register(evidence, domain: domain, canonical_payload: canonical_payload)
    end

    def evidence_with_identity(evidence)
      evidence_ledger.with_identity(evidence)
    end

    def evidence_payload_registered?(evidence, canonical_payload: nil)
      evidence_ledger.payload_registered?(evidence, canonical_payload: canonical_payload)
    end

    def runtime_nodes_by_name
      @runtime_nodes_by_name ||= method_nodes.reject(&:test).group_by(&:name).freeze
    end

    def canonical_receiver_lookup(site, owner, kind)
      entries = kind == :constant ? singleton_lookup_entries(owner) : instance_lookup_entries(owner)
      separator = kind == :constant ? '.' : '#'
      scoped_site = site.with(
        receiver_kind: kind,
        receiver_name: owner,
        metadata: site.metadata.merge('receiver_candidates' => [owner])
      )
      ordered_method_lookup(
        scoped_site,
        entries,
        reason: "cha_#{kind}_lookup",
        completeness_entries: [[owner, separator]]
      )
    end

    def register_result_evidences(result)
      records = result.respond_to?(:evidences) ? result.evidences : []
      Array(records).each do |evidence|
        record = evidence_with_identity(evidence)
        register_evidence(record) unless evidence_payload_registered?(record)
      end
    end

    def register_result_call_sites(result)
      sites = result.respond_to?(:derived_call_sites) ? result.derived_call_sites : []
      Array(sites).each do |site|
        raise TypeError, 'derived call sites must be CallSite values' unless site.is_a?(CallSite)

        existing = call_sites.select { |candidate| candidate.call_site_id == site.call_site_id }
        next if existing.include?(site)
        raise Error, "Conflicting derived call site identity: #{site.call_site_id}" if existing.any?

        call_sites << site
        resolution_ledger.register_call_site(site)
        @call_sites_by_message = nil
      end
    end

    def register_duplicate_definition_blockers
      method_nodes.reject(&:test).map(&:symbol_id).uniq.sort.each do |symbol_id|
        register_duplicate_definition_blocker(symbol_id)
      end
    end

    def register_duplicate_definition_blocker(symbol_id)
      definitions = definitions_for(symbol_id).reject(&:test)
      remove_blockers_matching do |blocker|
        blocker.kind == :duplicate_definition && blocker.scope_kind == :symbol && blocker.scope_value == symbol_id
      end
      return unless definitions.length > 1

      add_blocker(Blocker.new(
                    kind: :duplicate_definition,
                    scope_kind: :symbol,
                    scope_value: symbol_id,
                    source: :definition_index,
                    reason: 'Multiple production definitions have no proven activation order',
                    suggested_action: :review_definitions,
                    metadata: {
                      'caller_domain' => 'runtime',
                      'definition_count' => definitions.length,
                      'definition_ids' => definitions.map(&:graph_id).sort,
                      'locations' => definitions.map do |definition|
                        {
                          'definition_id' => definition.graph_id,
                          'file' => definition.file,
                          'line' => definition.line
                        }
                      end
                    }
                  ))
    end

    def apply_dynamic_edge(edge)
      caller = resolve_dynamic_reference(edge.caller_id)
      callee = resolve_dynamic_reference(edge.callee_id)
      record_dynamic_ambiguous_input(:edge_caller, caller)
      record_dynamic_ambiguous_input(:edge_callee, callee)
      mark_dynamic_alive(caller, edge.evidence)
      mark_dynamic_alive(callee, edge.evidence)
      materialized = precise_dynamic_resolution?(caller) && precise_dynamic_resolution?(callee)
      if materialized
        add_physical_edge(caller.fetch(:definitions).first.graph_id, callee.fetch(:definitions).first.graph_id,
                          edge.evidence)
      end
      register_evidence(edge.evidence) if caller.fetch(:definitions).empty? && callee.fetch(:definitions).empty?

      { caller: caller, callee: callee, materialized: materialized }
    end

    def apply_dynamic_alive(reference, evidence)
      resolution = resolve_dynamic_reference(reference)
      record_dynamic_ambiguous_input(:alive, resolution)
      mark_dynamic_alive(resolution, evidence)
      register_evidence(evidence) if resolution.fetch(:definitions).empty?
      resolution
    end

    def mark_dynamic_alive(resolution, evidence)
      resolution.fetch(:definitions).each do |definition|
        evidence_id = register_evidence(evidence, domain: definition.test ? :test : :runtime)
        next unless evidence_id

        store.dynamic_alive[definition.graph_id] ||= Set.new
        store.dynamic_alive[definition.graph_id] << evidence_id
      end
    end

    def precise_dynamic_resolution?(resolution)
      %i[exact unique].include?(resolution.fetch(:status))
    end

    def resolve_dynamic_reference(reference)
      normalized = normalize_dynamic_reference(reference)
      return resolve_legacy_dynamic_reference(normalized) if normalized.key?('identifier')
      return dynamic_resolution(normalized, :missing, []) unless normalized['symbol_id']

      definition = nodes.exact(normalized['definition_id']) if normalized['definition_id']
      exact_match = definition && dynamic_reference_matches?(definition, normalized)
      return dynamic_resolution(normalized, :exact, [definition]) if exact_match

      resolve_dynamic_reference_hints(normalized, definition_id_supplied: normalized.key?('definition_id'))
    end

    def normalize_dynamic_reference(reference)
      return { 'identifier' => reference.to_s } unless reference.is_a?(Hash)

      normalized = {}
      %w[definition_id symbol_id file].each do |key|
        value = reference[key] || reference[key.to_sym]
        normalized[key] = value.to_s unless value.nil? || value.to_s.empty?
      end
      line = reference['line'] || reference[:line]
      normalized['line'] = line.to_i unless line.nil?
      normalized
    end

    def resolve_legacy_dynamic_reference(normalized)
      lookup = nodes.lookup(normalized.fetch('identifier'))
      dynamic_resolution(normalized, lookup.status, lookup.definitions)
    end

    def resolve_dynamic_reference_hints(normalized, definition_id_supplied:)
      symbol_id = normalized['symbol_id']
      location_supplied = normalized.key?('file') || normalized.key?('line')
      return dynamic_resolution(normalized, :missing, []) unless symbol_id
      return dynamic_resolution(normalized, :missing, []) if definition_id_supplied && !location_supplied

      definitions = definitions_for(symbol_id)
      definitions = definitions.select { |node| node.file == normalized['file'] } if normalized.key?('file')
      definitions = definitions.select { |node| node.line.to_i == normalized['line'] } if normalized.key?('line')
      status = if definitions.empty?
                 :missing
               elsif definitions.one?
                 :unique
               else
                 :ambiguous
               end
      dynamic_resolution(normalized, status, definitions)
    end

    def dynamic_reference_matches?(definition, normalized)
      return false if normalized['symbol_id'] && definition.symbol_id != normalized['symbol_id']
      return false if normalized['file'] && definition.file != normalized['file']
      return false if normalized.key?('line') && definition.line.to_i != normalized['line']

      true
    end

    def dynamic_resolution(reference, status, definitions)
      { reference: reference.freeze, status: status, definitions: definitions.freeze }.freeze
    end

    def record_dynamic_ambiguous_input(kind, resolution)
      return unless resolution.fetch(:status) == :ambiguous

      record_definition_ambiguity(
        kind,
        { 'reference' => resolution.fetch(:reference) },
        resolution.fetch(:definitions)
      )
    end

    def register_incomplete_source_blockers
      incomplete_files.each do |file|
        errors = source_errors.select { |error| error.file == file }
        first_error = errors.first
        status = file_statuses.fetch(file)
        domain = source_domain(file)
        metadata = {
          'file' => file,
          'line' => first_error&.line || 1,
          'status' => status.to_s,
          'caller_domain' => domain.to_s,
          'source_errors' => errors.map(&:to_h)
        }
        add_blocker(Blocker.new(
                      kind: :parse_incomplete,
                      scope_kind: :file,
                      scope_value: file,
                      source: first_error || :ast_scanner,
                      reason: "Source file was #{status}; dead-code conclusions are incomplete",
                      metadata: metadata
                    ))
        next unless domain == :runtime

        add_blocker(Blocker.new(
                      kind: :parse_incomplete,
                      scope_kind: :global,
                      scope_value: '*',
                      source: first_error || :ast_scanner,
                      reason: "Runtime source file was #{status}; missing calls can affect any dead-code conclusion",
                      metadata: metadata.merge('impact' => 'missing_outgoing_calls')
                    ))
      end
    end

    def source_domain(file)
      source_nodes = nodes.values.select { |node| node.file == file }
      return file.start_with?('spec/', 'test/') ? :test : :runtime if source_nodes.empty?

      source_nodes.all?(&:test) ? :test : :runtime
    end

    def rta_candidates_for_receiver(site)
      exact = method_lookup(site).targets
      return exact unless exact.empty?

      candidate_nodes(site.message, domain: site.test ? :test : :runtime)
    end

    def self_method_lookup(site)
      caller = nodes.exact(site.caller_id)
      owner = caller&.owner || site.receiver_name
      return fallback_method_lookup(site, reason: 'unknown_self_owner') unless owner

      singleton = caller&.kind == :singleton_method || !caller&.method?
      entries = singleton ? singleton_lookup_entries(owner) : instance_lookup_entries(owner)
      separator = singleton ? '.' : '#'
      result = ordered_method_lookup(
        site,
        entries,
        reason: singleton ? 'singleton_self_lookup' : 'instance_self_lookup',
        completeness_entries: [[owner, separator]]
      )
      return result unless result.unknown?
      return result if singleton

      fallback_method_lookup(site, reason: 'self_lookup_fallback')
    end

    def super_method_lookup(site)
      caller = nodes.exact(site.caller_id)
      return fallback_method_lookup(site, reason: 'unknown_super_owner') unless caller&.owner

      separator = caller.kind == :singleton_method ? '.' : '#'
      info = class_info(caller.owner)
      return module_super_method_lookup(site, caller, separator) if info&.kind == :module && separator == '#'

      entries = separator == '.' ? singleton_lookup_entries(caller.owner) : instance_lookup_entries(caller.owner)
      current_index = entries.index([caller.owner, separator])
      return incomplete_method_lookup([], entries, 'current_implementation_not_in_lookup_chain') unless current_index

      ordered_method_lookup(
        site,
        entries.drop(current_index + 1),
        reason: 'super_next_implementation',
        completeness_entries: entries.first(current_index + 1)
      )
    end

    def module_super_method_lookup(site, caller, separator)
      hosts = class_infos.values.select { |info| info.kind == :class }.sort_by(&:id).flat_map do |host|
        [instance_lookup_entries(host.id), singleton_lookup_entries(host.id)].filter_map do |entries|
          index = entries.index([caller.owner, separator])
          entries.drop(index + 1) if index
        end
      end
      own_entries = instance_lookup_entries(caller.owner)
      own_index = own_entries.index([caller.owner, separator])
      hosts << own_entries.drop(own_index + 1) if own_index
      results = hosts.map do |entries|
        ordered_method_lookup(site, entries, reason: 'module_super_host_lookup', force_partial: true)
      end
      targets = results.flat_map(&:targets).uniq(&:graph_id).sort_by(&:graph_id)
      chain = results.flat_map(&:lookup_chain).uniq
      incomplete_method_lookup(targets, chain.map { |owner| [owner, '#'] }, 'module_super_open_hosts')
    end

    def ordered_method_lookup(site, entries, reason:, completeness_entries: [], force_partial: false)
      entries = Array(entries)
      target_index = entries.index do |owner, separator|
        definitions_for("#{owner}#{separator}#{site.message}").any?
      end
      unless target_index
        missing = method_missing_lookup(site, entries, reason, completeness_entries, force_partial)
        return missing if missing

        targets = dynamic_ancestry_candidates(site, [])
        return incomplete_method_lookup(targets, entries, "#{reason}_missing")
      end

      target_entry = entries.fetch(target_index)
      targets = definitions_for("#{target_entry.first}#{target_entry.last}#{site.message}")
      prefix = completeness_entries + entries.first(target_index + 1)
      complete = !force_partial && complete_lookup_prefix?(prefix) && !dynamic_lookup_chain?(entries) &&
                 !dynamic_ancestry_uncertain?(site)
      targets = dynamic_ancestry_candidates(site, targets) if dynamic_ancestry_uncertain?(site)
      return incomplete_method_lookup(targets, entries, "#{reason}_incomplete") unless complete

      if targets.any? { |target| protected_visibility_outcome(site, target) == :unknown }
        return incomplete_method_lookup(targets, entries, "#{reason}_protected_context_unknown")
      end

      accepted, target_rejections = apply_complete_target_constraints(site, targets)
      shadowed = shadowed_rejections(site.message, entries.drop(target_index + 1))
      MethodLookup.new(
        targets: accepted,
        status: :complete,
        rejected_targets: target_rejections + shadowed,
        lookup_chain: entries.map(&:first),
        reason: reason
      )
    end

    def method_missing_lookup(site, entries, reason, completeness_entries, force_partial)
      missing_index = entries.index do |owner, separator|
        definitions_for("#{owner}#{separator}method_missing").any?
      end
      return unless missing_index

      entry = entries.fetch(missing_index)
      targets = definitions_for("#{entry.first}#{entry.last}method_missing")
      prefix = completeness_entries + entries.first(missing_index + 1)
      complete = !force_partial && complete_lookup_prefix?(prefix) && !dynamic_lookup_chain?(entries) &&
                 !dynamic_ancestry_uncertain?(site)
      return incomplete_method_lookup(targets, entries, "#{reason}_method_missing_incomplete") unless complete

      MethodLookup.new(
        targets: targets,
        status: :complete,
        lookup_chain: entries.map(&:first),
        reason: "#{reason}_method_missing"
      )
    end

    def incomplete_method_lookup(targets, entries, reason)
      targets = Array(targets)
      MethodLookup.new(
        targets: targets,
        status: targets.empty? ? :unknown : :partial,
        lookup_chain: Array(entries).map { |entry| entry.is_a?(Array) ? entry.first : entry },
        reason: reason
      )
    end

    def fallback_method_lookup(site, reason:)
      domain = site.test ? :test : :runtime
      incomplete_method_lookup(ambiguous_fallback_candidates(site.message, domain: domain), [], reason)
    end

    def apply_complete_target_constraints(site, targets)
      accepted = []
      rejected = []
      targets.each do |target|
        visibility_reason = visibility_rejection_reason(site, target)
        if visibility_reason
          rejected << RejectedTarget.new(definition_id: target.graph_id, reason: visibility_reason)
        elsif arity_target_rejected?(site, target)
          rejected << RejectedTarget.new(definition_id: target.graph_id, reason: 'arity_mismatch')
        else
          accepted << target
        end
      end
      [accepted, rejected]
    end

    def visibility_rejection_reason(site, target)
      return 'protected_visibility' if protected_visibility_outcome(site, target) == :reject

      'private_visibility' if private_target_rejected?(site, target)
    end

    def protected_visibility_outcome(site, target)
      return :allow unless target.visibility == :protected

      original = site.metadata['original_message'] || site.metadata[:original_message]
      return :reject if original.to_s == 'public_send'
      return :allow if %w[send __send__ method].include?(original.to_s)
      return :allow if %i[implicit self super].include?(site.receiver_kind)

      caller_owner = nodes.exact(site.caller_id)&.owner
      receiver_owner = resolved_receiver_owner(site)
      return :unknown unless protected_context_known?(caller_owner, receiver_owner, target.owner)

      caller_family = cached_lookup_chain(caller_owner).include?(target.owner)
      receiver_family = cached_lookup_chain(receiver_owner).include?(target.owner)
      caller_family && receiver_family ? :allow : :reject
    end

    def protected_context_known?(*owners)
      owners.all? do |owner|
        info = class_info(owner)
        info && !info.dynamic
      end
    end

    def private_target_rejected?(site, target)
      return false unless target.visibility == :private
      return false if site.metadata['implicit_private_dispatch'] == true
      return false if %i[implicit self super].include?(site.receiver_kind)

      original = site.metadata['original_message'] || site.metadata[:original_message]
      return false if %w[send __send__ method].include?(original.to_s)

      if original.to_s == 'respond_to?'
        include_private = if site.metadata.key?('include_private')
                            site.metadata['include_private']
                          else
                            site.metadata[:include_private]
                          end
        return include_private == false
      end

      true
    end

    def arity_target_rejected?(site, target)
      arguments = site.metadata['arguments'] || site.metadata[:arguments]
      signature = method_signatures[target.graph_id]
      return false unless arguments.is_a?(Hash) && signature.is_a?(Hash)
      return false unless hash_value(arguments, 'complete') && hash_value(signature, 'complete')

      keywords = Array(hash_value(arguments, 'keywords')).map(&:to_s)
      required = Array(hash_value(signature, 'required_keywords')).map(&:to_s)
      accepted = Array(hash_value(signature, 'accepted_keywords')).map(&:to_s)
      keyword_rest = hash_value(signature, 'keyword_rest')
      accepts_keywords = hash_value(signature, 'accepts_keywords')
      accepts_keywords = required.any? || accepted.any? || keyword_rest if accepts_keywords.nil?
      no_keywords = hash_value(signature, 'no_keywords')

      count = hash_value(arguments, 'positional_count').to_i
      if keywords.any? && !accepts_keywords
        return true if no_keywords

        count += 1
      end

      minimum = hash_value(signature, 'minimum_positionals').to_i
      maximum = hash_value(signature, 'maximum_positionals')
      return true if count < minimum || (!maximum.nil? && count > maximum.to_i)
      return false unless accepts_keywords
      return true unless (required - keywords).empty?

      !keyword_rest && !(keywords - accepted).empty?
    end

    def hash_value(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_sym]
    end

    def shadowed_rejections(message, entries)
      entries.flat_map do |owner, separator|
        definitions_for("#{owner}#{separator}#{message}").map do |target|
          RejectedTarget.new(definition_id: target.graph_id, reason: 'shadowed_by_lookup_order')
        end
      end
    end

    def complete_lookup_prefix?(entries)
      entries.all? do |owner, _separator|
        info = class_info(owner)
        info && !info.dynamic
      end
    end

    def dynamic_lookup_chain?(entries)
      entries.any? { |owner, _separator| class_info(owner)&.dynamic }
    end

    def dynamic_ancestry_uncertain?(site)
      owners = receiver_candidates(site)
      owners = [nodes.exact(site.caller_id)&.owner].compact if owners.empty?
      key = [site.test ? :test : :runtime, owners.sort]
      return @dynamic_ancestry_cache[key] if @dynamic_ancestry_cache.key?(key)

      @dynamic_ancestry_cache[key] = @blockers.any? do |blocker|
        next false unless blocker.kind == :dynamic_ancestry
        next false unless blocker.caller_domain == :runtime || site.test
        next true if blocker.scope_kind == :global
        next false unless blocker.scope_kind == :owner

        Array(blocker.scope_value).map(&:to_s).intersect?(owners)
      end
    end

    def dynamic_ancestry_candidates(site, targets)
      return targets unless dynamic_ancestry_uncertain?(site)

      domain = site.test ? :test : :runtime
      (Array(targets) + ambiguous_fallback_candidates(site.message, domain: domain)).uniq(&:graph_id).sort_by(&:graph_id)
    end

    def resolved_receiver_owner(site)
      candidates = receiver_candidates(site)
      candidates.find { |owner| class_info(owner) } || candidates.first
    end

    def instance_lookup_entries(owner)
      cached_lookup_chain(owner).map { |candidate| [candidate, '#'] }
    end

    def singleton_lookup_entries(owner, seen = Set.new)
      top_level = seen.empty?
      @singleton_lookup_chain_cache ||= {}
      return @singleton_lookup_chain_cache[owner] if top_level && @singleton_lookup_chain_cache.key?(owner)
      return [] unless owner && seen.add?(owner)

      info = class_info(owner)
      result = if info
                 prepends = info.singleton_prepends.reverse.flat_map do |extension|
                   method_lookup_chain(extension).map { |candidate| [candidate, '#'] }
                 end
                 extensions = info.singleton_includes.reverse.flat_map do |extension|
                   method_lookup_chain(extension).map { |candidate| [candidate, '#'] }
                 end
                 [*prepends, [owner, '.'], *extensions, *singleton_lookup_entries(info.superclass, seen)]
               else
                 [[owner, '.']]
               end
      top_level ? (@singleton_lookup_chain_cache[owner] = result.freeze) : result
    end

    def receiver_candidates(site)
      candidates = site.metadata['receiver_candidates'] || site.metadata[:receiver_candidates]
      Array(candidates).compact.empty? ? [site.receiver_name].compact : Array(candidates).compact
    end

    def rta_candidate?(node, site)
      return true unless node.kind == :instance_method

      caller_owner = nodes[site.caller_id]&.owner
      return true if site.receiver_kind == :super
      return dispatched_instance_owner(caller_owner, site.message) == node.owner if %i[self implicit].include?(site.receiver_kind)

      return true if node.owner == caller_owner
      return true if class_info(node.owner)&.dynamic

      rta_instantiated_owners(site.message).include?(node.owner)
    end

    # RTA evaluates every candidate for a call site against the same set of
    # scanned allocations. Computing that set inside the candidate predicate
    # turns a single call site into O(candidates * instantiated_classes)
    # dispatch checks. Cache the dispatched owners once per message instead;
    # this preserves the conservative owner test while making the hot path
    # linear in the number of candidates.
    def rta_instantiated_owners(message)
      @rta_instantiated_owner_cache.fetch(message) do
        @rta_instantiated_owner_cache[message] = instantiated_classes.each_with_object(Set.new) do |owner, owners|
          dispatched = dispatched_instance_owner(owner, message)
          owners << dispatched if dispatched
        end
      end
    end

    def dispatched_instance_owner(owner, message)
      @dispatch_cache ||= {}
      key = [owner, message]
      if @dispatch_cache.key?(key)
        @resolution_cache_hits = @resolution_cache_hits.to_i + 1
        return @dispatch_cache[key]
      end

      @resolution_cache_misses = @resolution_cache_misses.to_i + 1

      @dispatch_cache[key] = cached_lookup_chain(owner).find do |candidate|
        definitions_for("#{candidate}##{message}").any?
      end
    end

    def cached_lookup_chain(owner)
      @lookup_chain_cache ||= {}
      @lookup_chain_cache[owner] ||= method_lookup_chain(owner)
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

      Analyzers::Dynamic::ObservationPolicy.compatible_merge(left, right)
    end

    def call_site_key(site)
      call_site_id = site['call_site_id'] || site[:call_site_id]
      return [:call_site_id, call_site_id] if call_site_id

      metadata = site['metadata'] || site[:metadata] || {}
      [
        site['caller_definition_id'] || site[:caller_definition_id] || site['caller_id'] || site[:caller_id],
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
      store.incoming_edges.clear
      store.physical_edges.each do |caller_id, callees|
        callees.each do |callee_id, evidences|
          store.incoming_edges[callee_id] ||= {}
          store.incoming_edges[callee_id][caller_id] = evidences
        end
      end
    end

    def resolve_definitions(identifier)
      nodes.resolve(identifier)
    end

    def add_physical_edge(caller_id, callee_id, evidence)
      caller = nodes.exact(caller_id)
      evidence_id = register_evidence(evidence, domain: caller&.test ? :test : :runtime)
      return unless evidence_id

      store.physical_edges[caller_id] ||= {}
      store.physical_edges[caller_id][callee_id] ||= Set.new
      store.physical_edges[caller_id][callee_id] << evidence_id
      store.incoming_edges[callee_id] ||= {}
      store.incoming_edges[callee_id][caller_id] = store.physical_edges[caller_id][callee_id]
    end

    def record_ambiguous_input(kind, identifier, definitions)
      return unless definitions.length > 1 && definitions_for(identifier).length > 1

      record_definition_ambiguity(kind, { 'identifier' => identifier }, definitions)
    end

    def record_definition_ambiguity(kind, reference, definitions)
      resolution = observation['definition_resolution'] ||= { 'ambiguous_input_count' => 0, 'ambiguous_inputs' => [] }
      resolution['ambiguous_input_count'] += 1
      resolution['ambiguous_inputs'] << reference.merge(
        'kind' => kind.to_s,
        'definition_ids' => definitions.map(&:graph_id).sort
      )
      resolution['ambiguous_inputs'] = resolution['ambiguous_inputs'].uniq.sort_by do |sample|
        [sample.fetch('kind'), canonical_dynamic_sample(sample), sample.fetch('definition_ids')]
      end.first(DynamicEvidenceTracking::SAMPLE_LIMIT)
    end

    def retain_known_instantiated_classes
      known_owners = method_nodes.map(&:owner).compact.to_set
      instantiated_classes.select! { |name| known_owners.include?(name) }
    end
  end
end
