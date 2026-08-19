# frozen_string_literal: true

require_relative '../models'
require_relative '../runtime_feedback'
require_relative '../analyzers/dynamic/observation_policy'
require_relative 'definition_index'
require_relative 'dynamic_evidence_tracking'
require_relative 'blocker_matching'
require_relative 'evidence_store'
require_relative 'resolution_store'
require_relative 'store'
require_relative 'evidence_ledger'
require_relative 'resolution_ledger'
require_relative 'transaction'
require_relative 'ruby_dispatch'

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
      @dispatch = Graph::RubyDispatch.new(self)
      @blockers = []
      initialize_blocker_indexes
      @observation = {}
      record_generated_macro_observation(scan_result.nodes)
      @resolution_ledger = Graph::ResolutionLedger.new(self)
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

      @dispatch.reset!
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
      @dispatch.fallback_resolution?(site, resolved: resolved)
    end

    # Public CallGraph methods remain stable while dispatch state lives in a
    # dedicated graph component.
    def method_nodes
      @dispatch.method_nodes
    end

    def nodes_by_name
      @dispatch.nodes_by_name
    end

    def class_info(owner)
      @dispatch.class_info(owner)
    end

    def descendants_of(owner)
      @dispatch.descendants_of(owner)
    end

    def modules_for(owner)
      @dispatch.modules_for(owner)
    end

    def candidate_nodes(message, domain: nil)
      @dispatch.candidate_nodes(message, domain: domain)
    end

    def ambiguous_fallback_candidates(message, domain: nil)
      @dispatch.ambiguous_fallback_candidates(message, domain: domain)
    end

    def ambiguity_exceeded?(message, domain: nil)
      @dispatch.ambiguity_exceeded?(message, domain: domain)
    end

    def ambiguous_resolution?
      @dispatch.ambiguous_resolution?
    end

    def owner_reachable_from_ancestor?(owner, ancestor)
      @dispatch.owner_reachable_from_ancestor?(owner, ancestor)
    end

    def resolve_call_site(site, rta: false)
      @dispatch.resolve_call_site(site, rta: rta)
    end

    def cha_method_lookup(site)
      @dispatch.cha_method_lookup(site)
    end

    def residual_scope_for(site)
      @dispatch.residual_scope_for(site)
    end

    def method_lookup(site)
      @dispatch.method_lookup(site)
    end

    def retain_rta_candidates(candidates, site)
      @dispatch.retain_rta_candidates(candidates, site)
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

    # Private compatibility surface used by blocker matching and legacy specs.
    def singleton_lookup_entries(owner, seen = Set.new)
      @dispatch.send(:singleton_lookup_entries, owner, seen)
    end

    def dispatched_instance_owner(owner, message)
      @dispatch.send(:dispatched_instance_owner, owner, message)
    end

    def cached_lookup_chain(owner)
      @dispatch.send(:cached_lookup_chain, owner)
    end

    def method_lookup_chain(owner, seen = Set.new)
      @dispatch.send(:method_lookup_chain, owner, seen)
    end

    def ancestor_chain(owner)
      @dispatch.send(:ancestor_chain, owner)
    end
  end
end
