# frozen_string_literal: true

module Necropsy
  class CallGraph
    include DynamicEvidenceTracking
    include EvidenceStore
    include BlockerMatching
    include ResolutionStore

    attr_reader :nodes, :call_sites, :instantiated_classes, :entry_points, :profiles, :observation, :class_infos,
                :entrypoint_hints, :ambiguity_limit, :file_statuses, :source_errors, :source_domains,
                :scope_diagnostics

    def initialize(scan_result, ambiguity_limit: 4)
      @nodes = DefinitionIndex.new
      @edges = {}
      @incoming_edges = {}
      initialize_evidence_store
      @call_sites = scan_result.call_sites
      @instantiated_classes = scan_result.instantiated_classes.dup
      @class_infos = scan_result.class_infos.to_h { |info| [info.id, info] }
      @entrypoint_hints = scan_result.entrypoint_hints
      @file_statuses = scan_result.file_statuses.to_h do |file, status|
        [file.to_s, status.to_sym]
      end
      @source_errors = scan_result.source_errors.dup
      @source_domains = scan_result.source_domains.to_h do |file, domain|
        [file.to_s, domain.to_sym]
      end
      @scope_diagnostics = scan_result.scope_diagnostics.dup
      @ambiguity_limit = ambiguity_limit
      @blockers = []
      initialize_blocker_indexes
      @entry_points = []
      @profiles = []
      @uncertainties = scan_result.uncertainties.to_h do |node_id, messages|
        [node_id, Array(messages).dup]
      end
      @dynamic_alive = {}
      @observation = {}
      initialize_resolution_store
      @descendants = {}
      @duplicate_blockers_initialized = false
      scan_result.nodes.each { |node| add_node(node) }
      register_duplicate_definition_blockers
      @duplicate_blockers_initialized = true
      register_incomplete_source_blockers
      retain_known_instantiated_classes
    end

    def add_node(node)
      existing = nodes.exact(node.graph_id)
      return existing if existing

      @method_nodes = nil
      @nodes_by_name = nil
      @dispatch_cache = nil
      @lookup_chain_cache = nil
      @owner_ancestor_cache = nil
      added = nodes.add(node)
      register_duplicate_definition_blocker(node.symbol_id) if @duplicate_blockers_initialized
      refresh_resolution_derived_state
      added
    end

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

    def apply_result(result)
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
          @uncertainties[resolved_id] ||= []
          @uncertainties[resolved_id].concat(Array(messages))
        end
      end
      Array(result.respond_to?(:blockers) ? result.blockers : []).each { |blocker| add_blocker(blocker) }
      observation.merge!(result.observation) { |_key, left, right| merge_observation(left, right) }
      record_dynamic_evidence(result, alive_matches, edge_matches) if dynamic_result
      register_result_resolutions(result)
      refresh_resolution_derived_state if !result.respond_to?(:resolutions) || result.resolutions.nil?
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

        @dynamic_alive[definition.graph_id] ||= Set.new
        @dynamic_alive[definition.graph_id] << evidence_id
      end
      true
    end

    def dynamic_alive?(node_id)
      resolve_definitions(node_id).any? do |definition|
        @dynamic_alive.fetch(definition.graph_id, Set.new).any? { |evidence_id| evidence_record(evidence_id) }
      end
    end

    def alive_evidences(node_id, projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      evidence_ids = resolve_definitions(node_id).flat_map do |definition|
        @dynamic_alive.fetch(definition.graph_id, Set.new).to_a
      end
      projected_evidence_records(evidence_ids.uniq, projection: projection, scope: scope)
    end

    def dynamic_enabled?
      @dynamic_alive.any?
    end

    def edges_from(node_id, projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      evidence_ids_by_callee = resolve_definitions(node_id).each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |definition, merged|
        @edges.fetch(definition.graph_id, {}).each do |callee_id, evidence_ids|
          merged[callee_id].merge(evidence_ids)
        end
      end
      evidence_ids_by_callee.each_with_object({}) do |(callee_id, evidence_ids), projected|
        records = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
        projected[callee_id] = records unless records.empty?
      end
    end

    def edges(projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      @edges.flat_map do |caller_id, callees|
        callees.filter_map do |callee_id, evidence_ids|
          evidences = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
          Edge.new(caller_id: caller_id, callee_id: callee_id, evidences: evidences) unless evidences.empty?
        end
      end.sort_by { |edge| [edge.caller_id, edge.callee_id] }
    end

    def edge_relations(projection: :conservative, scope: nil)
      projection = normalize_projection(projection)
      @edges.flat_map do |caller_id, callees|
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
        @incoming_edges.fetch(definition.graph_id, {}).filter_map do |caller_id, evidence_ids|
          evidences = projected_evidence_records(evidence_ids, projection: projection, scope: scope)
          Edge.new(caller_id: caller_id, callee_id: definition.graph_id, evidences: evidences) unless evidences.empty?
        end
      end.sort_by { |edge| [edge.caller_id, edge.callee_id] }
    end

    def uncertainties(node_id = nil)
      return @uncertainties unless node_id

      resolved = resolve_definitions(node_id)
      return @uncertainties.fetch(node_id, []) if resolved.empty?

      resolved.flat_map { |definition| @uncertainties.fetch(definition.graph_id, []) }.uniq
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
      nodes_by_name.fetch(message, [])
    end

    def ambiguous_fallback_candidates(message)
      candidates = candidate_nodes(message)
      return candidates if candidates.one?
      return [] if candidates.size > @ambiguity_limit

      candidates
    end

    def ambiguity_exceeded?(message)
      candidate_nodes(message).size > ambiguity_limit
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
      @edges.delete_if { |_caller_id, callees| callees.empty? }
      rebuild_incoming_edges
      refresh_resolution_derived_state
    end

    def fallback_resolution?(site, resolved: nil)
      resolved ||= resolve_call_site(site)
      return false if resolved.empty?

      case site.receiver_kind
      when :constant
        receiver_candidates(site).none? { |name| definitions_for("#{name}.#{site.message}").any? }
      when :instance
        receiver_candidates(site).none? { |name| definitions_for("#{name}##{site.message}").any? }
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

    def register_result_evidences(result)
      records = result.respond_to?(:evidences) ? result.evidences : []
      Array(records).each do |evidence|
        record = evidence_with_identity(evidence)
        register_evidence(record) unless evidence_payload_registered?(record)
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

        @dynamic_alive[definition.graph_id] ||= Set.new
        @dynamic_alive[definition.graph_id] << evidence_id
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

    def candidates_for_receiver(site)
      case site.receiver_kind
      when :constant
        exact = first_defined_symbol(receiver_candidates(site).map { |name| "#{name}.#{site.message}" })
        exact.empty? ? ambiguous_fallback_candidates(site.message) : exact
      when :instance
        exact = first_defined_symbol(receiver_candidates(site).map { |name| "#{name}##{site.message}" })
        exact.empty? ? ambiguous_fallback_candidates(site.message) : exact
      when :self
        same_owner_candidates(site)
      when :super
        super_candidates(site)
      when :implicit
        same_owner_candidates(site).then do |matches|
          matches.empty? ? ambiguous_fallback_candidates(site.message) : matches
        end
      else
        ambiguous_fallback_candidates(site.message)
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
      ids.flat_map { |id| definitions_for(id) }
    end

    def super_candidates(site)
      caller = nodes[site.caller_id]
      return [] unless caller&.owner

      separator = caller.kind == :singleton_method ? '.' : '#'
      owner = class_info(caller.owner)&.superclass
      while owner
        candidates = definitions_for("#{owner}#{separator}#{site.message}")
        return candidates unless candidates.empty?

        owner = class_info(owner)&.superclass
      end
      []
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

      instantiated_classes.any? { |owner| dispatched_instance_owner(owner, site.message) == node.owner }
    end

    def dispatched_instance_owner(owner, message)
      @dispatch_cache ||= {}
      key = [owner, message]
      return @dispatch_cache[key] if @dispatch_cache.key?(key)

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

      left.merge(right)
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
      @incoming_edges = {}
      @edges.each do |caller_id, callees|
        callees.each do |callee_id, evidences|
          @incoming_edges[callee_id] ||= {}
          @incoming_edges[callee_id][caller_id] = evidences
        end
      end
    end

    def resolve_definitions(identifier)
      nodes.resolve(identifier)
    end

    def first_defined_symbol(symbol_ids)
      symbol_ids.each do |symbol_id|
        definitions = definitions_for(symbol_id)
        return definitions unless definitions.empty?
      end
      []
    end

    def add_physical_edge(caller_id, callee_id, evidence)
      caller = nodes.exact(caller_id)
      evidence_id = register_evidence(evidence, domain: caller&.test ? :test : :runtime)
      return unless evidence_id

      @edges[caller_id] ||= {}
      @edges[caller_id][callee_id] ||= Set.new
      @edges[caller_id][callee_id] << evidence_id
      @incoming_edges[callee_id] ||= {}
      @incoming_edges[callee_id][caller_id] = @edges[caller_id][callee_id]
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
