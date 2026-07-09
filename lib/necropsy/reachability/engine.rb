# frozen_string_literal: true

module Necropsy
  module Reachability
    Result = Data.define(:runtime_alive, :test_alive)

    class Engine
      def initialize(graph)
        @graph = graph
      end

      def call
        runtime_roots = graph.entry_points.reject(&:test?).map(&:node_id)
        test_roots = graph.entry_points.select(&:test?).map(&:node_id)

        Result.new(
          runtime_alive: traverse(runtime_roots),
          test_alive: traverse(test_roots)
        )
      end

      private

      attr_reader :graph

      def traverse(roots)
        visited = Set.new
        queue = roots.compact.uniq

        until queue.empty?
          node_id = queue.shift
          next if visited.include?(node_id)

          visited << node_id
          graph.edges_from(node_id).each_key { |callee_id| queue << callee_id unless visited.include?(callee_id) }
        end

        visited
      end
    end
  end
end
