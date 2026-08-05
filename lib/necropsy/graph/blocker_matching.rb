# frozen_string_literal: true

module Necropsy
  module BlockerMatching
    def blockers
      @blockers.dup
    end

    def add_blocker(blocker)
      blocker, key = canonical_blocker(blocker)
      return blocker unless @blocker_keys.add?(key)

      @blockers << blocker
      index_blocker(blocker)
      blocker
    end

    # Test-source uncertainty is diagnostic-only for production findings. A test
    # call site cannot make a production definition callable in the deployed app.
    def matching_blockers(node_or_id, caller_domain: :runtime)
      node = node_or_id.is_a?(Node) ? node_or_id : nodes[node_or_id]
      return [] unless node

      blocker_candidates(node).select do |blocker|
        blocker.caller_domain == caller_domain.to_sym && blocker_matches_node?(blocker, node)
      end
    end

    private

    def initialize_blocker_indexes
      @blocker_keys = Set.new
      @blockers_by_message = Hash.new { |hash, key| hash[key] = [] }
      @exact_blockers_by_scope = Hash.new do |scopes, kind|
        scopes[kind] = Hash.new { |values, value| values[value] = [] }
      end
      @unmessaged_exact_owner_blockers = []
      @glob_blockers_by_scope = Hash.new { |scopes, kind| scopes[kind] = [] }
    end

    def remove_blockers_matching(&)
      retained = @blockers.reject(&)
      return if retained.length == @blockers.length

      @blockers = retained
      rebuild_blocker_indexes
    end

    def rebuild_blocker_indexes
      retained = @blockers
      initialize_blocker_indexes
      @blockers = []
      retained.each { |blocker| add_blocker(blocker) }
    end

    def index_blocker(blocker)
      kind = blocker.scope_kind.to_sym
      match = blocker_scope_match(blocker)
      if match == :glob
        @glob_blockers_by_scope[kind] << blocker
      else
        messages = blocker_index_messages(blocker).compact
        if messages.any?
          messages.each { |message| @blockers_by_message[message] << blocker }
        elsif kind == :owner
          @unmessaged_exact_owner_blockers << blocker
        else
          exact_scope_values(blocker).each { |value| @exact_blockers_by_scope[kind][value] << blocker }
        end
      end
    end

    def blocker_candidates(node)
      candidates = []
      candidates.concat(@blockers_by_message.fetch(node.name, []))
      candidates.concat(exact_scope_blocker_candidates(node))
      candidates.concat(unmessaged_owner_blocker_candidates(node))
      candidates.concat(glob_scope_blocker_candidates(node))
      candidates.uniq
    end

    def exact_scope_blocker_candidates(node)
      candidates = []
      candidates.concat(@exact_blockers_by_scope[:definition].fetch(node.graph_id, []))
      candidates.concat(@exact_blockers_by_scope[:symbol].fetch(node.symbol_id, []))
      candidates.concat(@exact_blockers_by_scope[:message].fetch(node.name, []))
      namespace_scope_values(node.owner).each do |namespace|
        candidates.concat(@exact_blockers_by_scope[:namespace].fetch(namespace, []))
      end
      candidates.concat(@exact_blockers_by_scope[:file].fetch(node.file.to_s, []))
      candidates.concat(@exact_blockers_by_scope[:global].values.flatten)
      candidates
    end

    def unmessaged_owner_blocker_candidates(node)
      @unmessaged_exact_owner_blockers.select do |blocker|
        exact_scope_values(blocker).any? { |owner| blocker_owner_matches?(blocker, node, owner) }
      end
    end

    def namespace_scope_values(owner)
      parts = owner.to_s.split('::')
      parts.length.times.map { |index| parts.first(index + 1).join('::') }
    end

    def glob_scope_blocker_candidates(node)
      @glob_blockers_by_scope.values.flatten.select do |blocker|
        blocker_glob_scope_matches_node?(blocker, node)
      end
    end

    def blocker_index_messages(blocker)
      return Array(blocker.scope_value).compact.map(&:to_s) if blocker.scope_kind.to_sym == :message
      return [blocker.message&.to_s] unless blocker.scope_kind.to_sym == :symbol

      Array(blocker.scope_value).map { |symbol_id| logical_method_name(symbol_id) }.uniq
    end

    def exact_scope_values(blocker)
      Array(blocker.scope_value).compact.map(&:to_s)
    end

    def logical_method_name(symbol_id)
      value = symbol_id.to_s
      separator = value.index(/[.#]/)
      separator ? value[(separator + 1)..] : value
    end

    def blocker_key(blocker)
      metadata = blocker.metadata
      [
        blocker.kind.to_s,
        blocker.scope_kind.to_s,
        canonical_key_value(blocker.scope_value),
        canonical_key_value(blocker.source),
        metadata['file'] || metadata[:file],
        metadata['line'] || metadata[:line],
        metadata['caller_id'] || metadata[:caller_id],
        blocker.caller_domain.to_s,
        metadata['caller_kind'] || metadata[:caller_kind],
        metadata['receiver_kind'] || metadata[:receiver_kind],
        metadata['original_message'] || metadata[:original_message],
        metadata['call_site_id'] || metadata[:call_site_id],
        metadata['producer'] || metadata[:producer],
        metadata['producer_version'] || metadata[:producer_version],
        metadata['resolution_record_id'] || metadata[:resolution_record_id],
        canonical_key_value(metadata['assumptions'] || metadata[:assumptions]),
        canonical_key_value(
          metadata['known_target_definition_ids'] || metadata[:known_target_definition_ids]
        ),
        blocker_scope_match(blocker).to_s,
        metadata.fetch('include_private') { metadata[:include_private] },
        blocker.message&.to_s,
        blocker.reason.to_s
      ].freeze
    end

    def canonical_key_value(value)
      BoundedCanonicalizer.dump(value)
    end

    def canonical_blocker(blocker)
      [blocker, blocker_key(blocker)]
    rescue BoundedCanonicalizer::Error, SystemStackError => e
      sanitized = uncanonicalizable_blocker(blocker, e)
      [sanitized, blocker_key(sanitized)]
    end

    def uncanonicalizable_blocker(blocker, error)
      Blocker.new(
        kind: :blocker_invalid,
        scope_kind: :global,
        scope_value: '*',
        source: :blocker_store,
        reason: 'Analyzer blocker could not be canonicalized safely',
        suggested_action: :fix_analyzer,
        metadata: {
          'caller_domain' => safe_blocker_domain(blocker),
          'receiver_kind' => 'implicit',
          'original_kind' => blocker.kind.to_s,
          'original_source_type' => blocker.source.class.name.to_s,
          'canonicalization_error' => error.class.name
        }
      )
    end

    def safe_blocker_domain(blocker)
      blocker.caller_domain.to_s
    rescue StandardError, SystemStackError
      'runtime'
    end

    def blocker_matches_node?(blocker, node)
      return false if blocker_known_targets(blocker).include?(node.graph_id)
      return false unless blocker_message_matches?(blocker, node)
      return false unless blocker_visibility_matches?(blocker, node)
      return blocker_glob_scope_matches_node?(blocker, node) if blocker_scope_match(blocker) == :glob

      values = Array(blocker.scope_value).compact.map(&:to_s)
      case blocker.scope_kind.to_sym
      when :definition
        values.include?(node.graph_id)
      when :owner
        values.any? { |owner| blocker_owner_matches?(blocker, node, owner) }
      when :namespace
        values.any? { |namespace| node.owner == namespace || node.owner&.start_with?("#{namespace}::") }
      when :file
        values.include?(node.file)
      when :symbol
        values.include?(node.symbol_id)
      when :message, :global
        true
      else
        false
      end
    end

    def blocker_known_targets(blocker)
      metadata = blocker.metadata
      Array(metadata['known_target_definition_ids'] || metadata[:known_target_definition_ids]).map(&:to_s)
    end

    def blocker_message_matches?(blocker, node)
      return true if blocker.scope_kind.to_sym == :symbol
      if blocker.scope_kind.to_sym == :message && blocker_scope_match(blocker) == :glob
        return scope_patterns(blocker).any? { |pattern| File.fnmatch?(pattern, node.name) }
      end

      blocker.message.nil? || blocker.message.to_s == node.name
    end

    def blocker_scope_match(blocker)
      value = blocker.metadata['scope_match'] || blocker.metadata[:scope_match] || :exact
      value.to_sym
    end

    def blocker_glob_scope_matches_node?(blocker, node)
      values = glob_scope_node_values(blocker.scope_kind.to_sym, node)
      return true if blocker.scope_kind.to_sym == :global

      scope_patterns(blocker).any? do |pattern|
        values.any? { |value| File.fnmatch?(pattern, value, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end
    end

    def glob_scope_node_values(kind, node)
      case kind
      when :definition then [node.graph_id]
      when :symbol then [node.symbol_id]
      when :message then [node.name]
      when :owner then [node.owner].compact
      when :namespace then namespace_scope_values(node.owner)
      when :file then [node.file]
      else []
      end.map(&:to_s)
    end

    def scope_patterns(blocker)
      Array(blocker.scope_value).compact.map(&:to_s)
    end

    def blocker_visibility_matches?(blocker, node)
      return true if %i[analyzer_failure duplicate_definition parse_incomplete].include?(blocker.kind.to_sym)

      metadata = blocker.metadata
      receiver_kind = (metadata['receiver_kind'] || metadata[:receiver_kind])&.to_sym
      original_message = (metadata['original_message'] || metadata[:original_message])&.to_s
      return node.visibility == :public if original_message == 'public_send'
      return true if %w[send __send__ method].include?(original_message)
      return respond_to_include_private(metadata) != false if original_message == 'respond_to?'
      return true if %i[implicit self super].include?(receiver_kind)

      node.visibility != :private
    end

    def respond_to_include_private(metadata)
      return metadata['include_private'] if metadata.key?('include_private')
      return metadata[:include_private] if metadata.key?(:include_private)

      false
    end

    def blocker_owner_matches?(blocker, node, owner)
      receiver_kind = (blocker.metadata['receiver_kind'] || blocker.metadata[:receiver_kind])&.to_sym
      caller_kind = (blocker.metadata['caller_kind'] || blocker.metadata[:caller_kind])&.to_sym
      if receiver_kind == :constant || (%i[implicit self].include?(receiver_kind) && caller_kind == :singleton_method)
        return constant_owner_matches?(node, owner)
      end

      if receiver_kind == :super
        expected_kind = caller_kind == :singleton_method ? :singleton_method : :instance_method
        return node.kind == expected_kind && super_dispatch_owners(owner).include?(node.owner)
      end

      node.kind == :instance_method && instance_dispatch_owners(owner).include?(node.owner)
    end

    def constant_owner_matches?(node, owner)
      return true if node.kind == :singleton_method && constant_dispatch_owners(owner).include?(node.owner)

      node.kind == :instance_method && Array(class_info(owner)&.extends).include?(node.owner)
    end

    def constant_dispatch_owners(owner)
      [owner, *ancestor_chain(owner), *Array(class_info(owner)&.extends)].compact.uniq
    end

    def super_dispatch_owners(owner)
      ancestor_chain(owner).flat_map { |candidate| cached_lookup_chain(candidate) }.uniq
    end

    def instance_dispatch_owners(owner)
      descendants_of(owner).flat_map { |candidate| cached_lookup_chain(candidate) }.uniq
    end
  end
end
