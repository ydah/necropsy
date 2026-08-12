# frozen_string_literal: true

require 'prism'

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
        gemspec_metadata(project).flat_map do |metadata|
          metadata.fetch(:require_paths).flat_map do |require_path|
            name = metadata.fetch(:name)
            ["#{require_path}/#{name.tr('-', '/')}.rb", "#{require_path}/#{name.tr('-', '_')}.rb"]
          end
        end.uniq.select { |relative| File.file?(File.join(project.root, relative)) }
      end

      def gemspec_metadata(project)
        project.reference_files.filter_map do |path|
          relative = project.relative_path(path)
          next unless relative.match?(%r{\A[^/]+\.gemspec\z})

          parse_gemspec(File.read(path))
        rescue SystemCallError, EncodingError
          nil
        end
      end

      def parse_gemspec(source)
        result = Prism.parse(source)
        return if result.failure?

        specification = find_specification_call(result.value)
        return unless specification&.block

        parameter = required_block_parameter(specification.block)
        return unless parameter.respond_to?(:name)

        assignments = specification_assignments(specification.block.body, parameter.name)
        name_node = first_argument(assignments[:name])
        name = name_node.unescaped.to_s if name_node.is_a?(Prism::StringNode)
        return if name.to_s.empty?

        paths_node = first_argument(assignments[:require_paths])
        paths = literal_string_array(paths_node)
        { name: name, require_paths: paths.empty? ? ['lib'] : paths }
      end

      def required_block_parameter(block)
        block_parameters = block.parameters
        parameters = block_parameters.parameters if block_parameters
        Array(parameters&.requireds).first
      end

      def first_argument(call)
        arguments = call.arguments if call
        Array(arguments&.arguments).first
      end

      def find_specification_call(root)
        pending = [root]
        until pending.empty?
          node = pending.pop
          return node if node.is_a?(Prism::CallNode) && node.name == :new &&
                         constant_name(node.receiver) == 'Gem::Specification'

          pending.concat(node.child_nodes.compact)
        end
      end

      def specification_assignments(root, parameter_name)
        pending = [root]
        assignments = {}
        until pending.empty?
          node = pending.pop
          if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::LocalVariableReadNode) &&
             node.receiver.name == parameter_name
            assignments[:name] = node if node.name == :name=
            assignments[:require_paths] = node if node.name == :require_paths=
          end
          pending.concat(node.child_nodes.compact)
        end
        assignments
      end

      def literal_string_array(node)
        return [] unless node.is_a?(Prism::ArrayNode) && !node.contains_splat?
        return [] unless node.elements.all?(Prism::StringNode)

        node.elements.map { |element| element.unescaped.to_s }.reject(&:empty?).uniq.sort
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          [constant_name(node.parent), node.name.to_s].compact.join('::')
        end
      end
    end
  end
end
