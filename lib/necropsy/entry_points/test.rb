# frozen_string_literal: true

module Necropsy
  module EntryPoints
    class Test
      def apply(graph, _project)
        graph.nodes.values.select { |node| node.kind == :block_entry && node.test }.each do |node|
          graph.add_entry_point(node.graph_id, :test_suite)
        end
      end
    end
  end
end
