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

          graph.add_entry_point(node.graph_id, :main_script)
        end

        project.config.entry_point_patterns.each do |pattern|
          graph.nodes.each_value do |node|
            graph.add_entry_point(node.graph_id, :public_api_declared) if File.fnmatch?(pattern, node.symbol_id)
          end
        end

        api_files = primary_library_files(project)
        graph.method_nodes.each do |node|
          next unless api_files.include?(node.file)
          next unless node.kind == :singleton_method && node.visibility == :public

          graph.add_entry_point(node.graph_id, :public_api_declared)
        end
      end

      private

      def primary_library_files(project)
        gem_names(project).flat_map do |name|
          ["lib/#{name.tr('-', '/')}.rb", "lib/#{name.tr('-', '_')}.rb"]
        end.uniq.select { |relative| File.file?(File.join(project.root, relative)) }
      end

      def gem_names(project)
        Dir.glob(File.join(project.root, '*.gemspec')).filter_map do |path|
          File.read(path)[/\.name\s*=\s*["']([^"']+)["']/, 1]
        rescue SystemCallError, EncodingError
          nil
        end
      end
    end
  end
end
