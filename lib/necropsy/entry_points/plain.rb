# frozen_string_literal: true

module Necropsy
  module EntryPoints
    class Plain
      SCRIPT_PATTERNS = [
        'bin/*',
        'exe/*',
        'Rakefile',
        '**/*.rake',
        '*.gemspec'
      ].freeze

      def apply(graph, project)
        graph.nodes.values.select { |node| node.kind == :block_entry && !node.test }.each do |node|
          next unless SCRIPT_PATTERNS.any? { |pattern| File.fnmatch?(pattern, node.file, File::FNM_PATHNAME) }

          graph.add_entry_point(node.id, :main_script)
        end

        project.config.entry_point_patterns.each do |pattern|
          graph.nodes.each_key do |node_id|
            graph.add_entry_point(node_id, :public_api_declared) if File.fnmatch?(pattern, node_id)
          end
        end

        graph.method_nodes.each do |node|
          next unless node.file == 'lib/necropsy.rb'
          next unless node.kind == :singleton_method && node.owner == 'Necropsy'

          graph.add_entry_point(node.id, :public_api_declared)
        end
      end
    end
  end
end
