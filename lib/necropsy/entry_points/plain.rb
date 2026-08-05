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
          pattern = SCRIPT_PATTERNS.find { |candidate| File.fnmatch?(candidate, node.file, File::FNM_PATHNAME) }
          next unless pattern

          graph.add_entry_point(
            node.graph_id,
            :main_script,
            domain: :runtime,
            evidence: { 'type' => 'path_policy', 'pattern' => pattern, 'file' => node.file }
          )
        end

        project.config.entry_point_patterns.each do |pattern|
          graph.nodes.each_value do |node|
            next if node.test
            next unless File.fnmatch?(pattern, node.symbol_id)

            graph.add_entry_point(
              node.graph_id,
              :public_api_declared,
              domain: project.config.library_world? ? :external : :runtime,
              evidence: { 'type' => 'configured_pattern', 'pattern' => pattern }
            )
          end
        end

        return if project.config.library_world?

        api_files = primary_library_files(project)
        graph.method_nodes.each do |node|
          next unless api_files.include?(node.file)
          next unless node.kind == :singleton_method && node.visibility == :public

          graph.add_entry_point(
            node.graph_id,
            :public_api_declared,
            domain: :runtime,
            evidence: { 'type' => 'gem_entry_file', 'file' => node.file }
          )
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
