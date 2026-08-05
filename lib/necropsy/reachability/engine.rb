# frozen_string_literal: true

module Necropsy
  module Reachability
    Result = Data.define(:runtime_paths, :test_paths, :external_paths) do
      class << self
        alias_method :data_new, :new

        def new(*values, **attributes)
          return data_new(runtime_paths: values[0], test_paths: values[1], external_paths: {}) if values.length == 2 && attributes.empty?

          data_new(*values, **attributes)
        end
        alias_method :[], :new

        private :data_new
      end

      def initialize(runtime_paths:, test_paths:, external_paths: {})
        super
      end

      def runtime_alive
        runtime_paths.keys
      end

      def test_alive
        test_paths.keys
      end

      def external_alive
        external_paths.keys
      end

      def witness(node_id, kind: :runtime)
        paths = paths_for(kind)
        return unless paths.key?(node_id)

        chain = []
        current = node_id
        while current
          chain.unshift(current)
          current = paths[current]
        end
        chain
      end

      private

      def paths_for(kind)
        case kind.to_sym
        when :runtime then runtime_paths
        when :test then test_paths
        when :external then external_paths
        else raise ArgumentError, 'kind must be runtime, test, or external'
        end
      end
    end

    class Engine
      def initialize(graph, projection: :conservative, scope: nil)
        @graph = graph
        @projection = EvidenceStore.normalize_projection(projection)
        @scope = scope
      end

      def call
        roots = graph.entry_points.group_by(&:domain)

        Result.new(
          runtime_paths: traverse(roots.fetch(:runtime, []).map(&:node_id), domain: :runtime),
          test_paths: traverse(roots.fetch(:test, []).map(&:node_id), domain: :test),
          external_paths: traverse(roots.fetch(:external, []).map(&:node_id), domain: :external)
        )
      end

      private

      attr_reader :graph, :projection, :scope

      def traverse(roots, domain:)
        visited = {}
        queue = roots.compact.uniq.select { |node_id| traversable_in_domain?(node_id, domain) }
        queue.each { |node_id| visited[node_id] = nil }

        until queue.empty?
          node_id = queue.shift
          graph.edges_from(node_id, projection: projection, scope: scope).each_key do |callee_id|
            next if visited.key?(callee_id)
            next unless traversable_in_domain?(callee_id, domain)

            visited[callee_id] = node_id
            queue << callee_id
          end
        end

        visited
      end

      def traversable_in_domain?(node_id, domain)
        domain == :test || !graph.nodes.fetch(node_id).test
      end
    end
  end
end
