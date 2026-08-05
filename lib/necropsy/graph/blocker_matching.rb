# frozen_string_literal: true

module Necropsy
  module BlockerMatching
    def blockers
      @blockers.dup
    end

    def add_blocker(blocker)
      key = blocker_key(blocker)
      return blocker unless @blocker_keys.add?(key)

      @blockers << blocker
      blocker_index_messages(blocker).each { |message| @blockers_by_message[message] << blocker }
      blocker
    end

    # Test-source uncertainty is diagnostic-only for production findings. A test
    # call site cannot make a production definition callable in the deployed app.
    def matching_blockers(node_or_id, caller_domain: :runtime)
      node = node_or_id.is_a?(Node) ? node_or_id : nodes[node_or_id]
      return [] unless node

      candidates = @blockers_by_message.fetch(node.name, []) + @blockers_by_message.fetch(nil, [])
      candidates.select do |blocker|
        blocker.caller_domain == caller_domain.to_sym && blocker_matches_node?(blocker, node)
      end
    end

    private

    def remove_blockers_matching(&)
      removed = @blockers.select(&)
      return if removed.empty?

      @blockers -= removed
      rebuild_blocker_indexes
    end

    def rebuild_blocker_indexes
      @blocker_keys = Set.new
      @blockers_by_message = Hash.new { |hash, key| hash[key] = [] }
      retained = @blockers
      @blockers = []
      retained.each { |blocker| add_blocker(blocker) }
    end

    def blocker_index_messages(blocker)
      return [blocker.message&.to_s] unless blocker.scope_kind.to_sym == :symbol

      Array(blocker.scope_value).map { |symbol_id| logical_method_name(symbol_id) }.uniq
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
        metadata.fetch('include_private') { metadata[:include_private] },
        blocker.message&.to_s,
        blocker.reason.to_s
      ].freeze
    end

    def canonical_key_value(value)
      case value
      when Array
        value.map { |item| canonical_key_value(item) }.sort_by(&:to_s)
      when Hash
        value.keys.sort_by(&:to_s).map { |key| [key.to_s, canonical_key_value(value.fetch(key))] }
      else
        value.to_s
      end
    end

    def blocker_matches_node?(blocker, node)
      return false unless blocker_message_matches?(blocker, node)
      return false unless blocker_visibility_matches?(blocker, node)

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

    def blocker_message_matches?(blocker, node)
      return true if blocker.scope_kind.to_sym == :symbol

      blocker.message.nil? || blocker.message.to_s == node.name
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
