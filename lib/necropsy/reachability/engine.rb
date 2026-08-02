# frozen_string_literal: true

module Necropsy
  module Reachability
    Result = Data.define(:runtime_paths, :test_paths) do
      def runtime_alive
        runtime_paths.keys
      end

      def test_alive
        test_paths.keys
      end

      def witness(node_id, kind: :runtime)
        paths = kind == :runtime ? runtime_paths : test_paths
        return unless paths.key?(node_id)

        chain = []
        current = node_id
        while current
          chain.unshift(current)
          current = paths[current]
        end
        chain
      end
    end

    class Engine
      def initialize(graph)
        @graph = graph
      end

      def call
        runtime_roots = graph.entry_points.reject(&:test?).map(&:node_id)
        test_roots = graph.entry_points.select(&:test?).map(&:node_id)

        Result.new(
          runtime_paths: traverse(runtime_roots),
          test_paths: traverse(test_roots)
        )
      end

      private

      attr_reader :graph

      def traverse(roots)
        visited = {}
        queue = roots.compact.uniq
        queue.each { |node_id| visited[node_id] = nil }

        until queue.empty?
          node_id = queue.shift
          graph.edges_from(node_id).each_key do |callee_id|
            next if visited.key?(callee_id)

            visited[callee_id] = node_id
            queue << callee_id
          end
        end

        visited
      end
    end
  end
end
