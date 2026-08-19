# frozen_string_literal: true

module Necropsy
  module Graph
    # Owns Ruby's receiver lookup and static dispatch candidate rules.
    #
    # CallGraph remains the public facade, while this object owns the mutable
    # lookup caches and all CHA/RTA candidate derivation. The graph is kept as
    # a context so definition and blocker state remain in their existing
    # boundaries without duplicating them here.
    class RubyDispatch
      attr_reader :graph

      def initialize(graph)
        @graph = graph
        reset!
      end

      def reset!
        @method_nodes = nil
        @nodes_by_name = nil
        @runtime_nodes_by_name = nil
        @descendants = {}
        @dispatch_cache = {}
        @lookup_chain_cache = {}
        @singleton_lookup_chain_cache = {}
        @owner_ancestor_cache = {}
        @flow_lookup_cache = {}
        @rta_instantiated_owner_cache = {}
        @dynamic_ancestry_cache = {}
      end

      def nodes
        graph.nodes
      end

      def class_infos
        graph.class_infos
      end

      def method_signatures
        graph.method_signatures
      end

      def instantiated_classes
        graph.instantiated_classes
      end

      def blockers
        graph.blockers
      end

      def ambiguity_limit
        graph.ambiguity_limit
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
            queue.concat(direct_subclasses.fetch(candidate, []))
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
        return [] if candidates.size > ambiguity_limit

        candidates
      end

      def ambiguity_exceeded?(message, domain: nil)
        candidate_nodes(message, domain: domain).size > ambiguity_limit
      end

      def ambiguous_resolution?
        ambiguity_limit > 1
      end

      def owner_reachable_from_ancestor?(owner, ancestor)
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

      def retain_rta_candidates(candidates, site)
        candidates.select { |node| rta_candidate?(node, site) }
      end

      def fallback_resolution?(site, resolved: nil)
        resolved ||= resolve_call_site(site)
        return false if resolved.empty?

        lookup = method_lookup(site)
        domain = site.test ? :test : :runtime
        fallback = ambiguous_fallback_candidates(site.message, domain: domain)
        !lookup.complete? && resolved.map(&:graph_id).sort == fallback.map(&:graph_id).sort
      end

      private

      def direct_subclasses
        @direct_subclasses ||= begin
          subclasses = Hash.new { |hash, key| hash[key] = [] }
          class_infos.each_value do |info|
            subclasses[info.superclass] << info.id if info.superclass
          end
          subclasses.each_value(&:sort!)
          subclasses
        end
      end

      def runtime_nodes_by_name
        @runtime_nodes_by_name ||= method_nodes.reject(&:test).group_by(&:name).freeze
      end

      def definitions_for(symbol_id)
        nodes.definitions_for(symbol_id)
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

      def flow_instance_method_lookup(site)
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
        blockers.any? do |blocker|
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

        @dynamic_ancestry_cache[key] = blockers.any? do |blocker|
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
      # scanned allocations. Cache dispatched owners once per message so the
      # candidate path stays linear in the number of candidates.
      def rta_instantiated_owners(message)
        @rta_instantiated_owner_cache.fetch(message) do
          @rta_instantiated_owner_cache[message] = instantiated_classes.each_with_object(Set.new) do |owner, owners|
            dispatched = dispatched_instance_owner(owner, message)
            owners << dispatched if dispatched
          end
        end
      end

      def dispatched_instance_owner(owner, message)
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
    end
  end
end
