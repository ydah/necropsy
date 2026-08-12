# frozen_string_literal: true

require 'prism'

module Necropsy
  module EntryPoints
    class Rails
      ROUTE_VERBS = %w[get post put patch delete match].freeze
      RESTFUL_ACTIONS = %w[index show new create edit update destroy].freeze
      SINGULAR_ACTIONS = %w[show new create edit update destroy].freeze
      IRREGULAR_PLURALS = { 'person' => 'people', 'man' => 'men', 'woman' => 'women', 'child' => 'children' }.freeze
      RouteContext = Struct.new(:modules, :resource, :controller, keyword_init: true)

      def apply(graph, project)
        return unless project.config.rails_enabled?(reference_files: project.reference_files)

        @route_blockers = []

        referenced_view_methods = view_method_names(project)
        graph.method_nodes.each do |node|
          case node.file
          when %r{\Aapp/jobs/}
            graph.add_entry_point(node.graph_id, :job_perform) if node.name == 'perform'
          when %r{\Aapp/mailers/}
            if node.kind == :instance_method && node.visibility == :public
              graph.add_entry_point(node.graph_id,
                                    :mailer_action)
            end
          when %r{\Aapp/helpers/}
            graph.add_entry_point(node.graph_id, :rails_view_helper) if referenced_view_methods.include?(node.name)
          when %r{\Aapp/components/}
            graph.add_entry_point(node.graph_id, :rails_component) if component_entrypoint?(node)
          when %r{\Adb/migrate/}
            graph.add_entry_point(node.graph_id, :rails_migration) if %w[change up down].include?(node.name)
          end

          if node.file.start_with?('app/') && !node.file.start_with?('app/helpers/', 'app/components/') &&
             referenced_view_methods.include?(node.name)
            graph.add_entry_point(node.graph_id, :rails_view_reference)
          end
        end

        graph.nodes.values.select do |node|
          node.kind == :block_entry && node.file.start_with?('config/initializers/')
        end.each do |node|
          graph.add_entry_point(node.graph_id, :callback_registered)
        end

        route_entry_points(project).each do |node_id|
          matching_route_nodes(graph, node_id).each do |matching_id|
            graph.add_entry_point(matching_id, :rails_route)
          end
        end
        @route_blockers.each { |blocker| graph.add_blocker(blocker) }
      end

      private

      def route_entry_points(project)
        routes = File.join(project.root, 'config/routes.rb')
        parse_route_file(project, routes, seen: {}, concerns: {})
      end

      def parse_route_file(project, path, seen:, concerns:)
        previous_route_path = @current_route_path
        expanded = File.expand_path(path, project.root)
        return [] unless project.reference_file?(expanded)
        return [] if seen[expanded]

        seen[expanded] = true
        @current_route_path = project.relative_path(expanded)
        source = File.read(expanded)
        result = Prism.parse(source)
        if result.failure?
          @route_blockers << route_health_blocker(
            @current_route_path, result.errors.first&.location&.start_line, 'routes.rb could not be parsed'
          )
          return []
        end

        parse_route_statements(
          result.value.statements,
          source: source,
          project: project,
          seen: seen,
          concerns: concerns,
          context: RouteContext.new(modules: [], resource: nil)
        )
      rescue SystemCallError, EncodingError => e
        @route_blockers << route_health_blocker(
          @current_route_path || project.relative_path(expanded), 1,
          "route source could not be read: #{e.class}"
        )
        []
      ensure
        @current_route_path = previous_route_path
      end

      def parse_route_statements(statements, source:, project:, seen:, concerns:, context:)
        Array(statements&.body).flat_map do |statement|
          parse_route_statement(statement, source: source, project: project, seen: seen, concerns: concerns,
                                           context: context)
        end.compact.uniq
      end

      def parse_route_statement(statement, source:, project:, seen:, concerns:, context:)
        unless statement.is_a?(Prism::CallNode)
          return statement.child_nodes.compact.flat_map do |child|
            parse_route_statement(child, source: source, project: project, seen: seen, concerns: concerns,
                                         context: context)
          end
        end

        call_source = route_call_source(statement, source)
        record_dynamic_route(statement, context) if dynamic_route_statement?(statement)
        if statement.name == :concern && statement.block
          name = literal_route_argument(statement.arguments&.arguments&.first)
          concerns[name] = [statement.block.body, source] if name
          return []
        end

        targets = route_targets(call_source, context)
        targets.concat(route_file_targets(call_source, project, seen, concerns))
        targets.concat(concern_targets(call_source, context, project, seen, concerns))
        return targets unless statement.block

        child_context = nested_route_context(call_source, context)
        targets.concat(
          parse_route_statements(
            statement.block.body,
            source: source,
            project: project,
            seen: seen,
            concerns: concerns,
            context: child_context
          )
        )
      end

      def route_call_source(node, source)
        finish = node.block ? node.block.opening_loc.start_offset : node.location.end_offset
        source.byteslice(node.location.start_offset...finish).gsub(/\s+/, ' ').strip
      end

      def literal_route_argument(node)
        return unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped.to_s
      end

      def dynamic_route_statement?(node)
        return false unless ROUTE_VERBS.include?(node.name.to_s) ||
                            %i[root resources resource mount namespace scope controller].include?(node.name)

        Array(node.arguments&.arguments).any? { |argument| !literal_route_value?(argument) }
      end

      def literal_route_value?(node)
        case node
        when Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::TrueNode, Prism::FalseNode,
             Prism::NilNode
          true
        when Prism::KeywordHashNode, Prism::HashNode
          Array(node.elements).all? do |element|
            element.is_a?(Prism::AssocNode) && literal_route_value?(element.value)
          end
        when Prism::ArrayNode
          !node.contains_splat? && node.elements.all? { |element| literal_route_value?(element) }
        else
          false
        end
      end

      def record_dynamic_route(statement, context)
        arguments = Array(statement.arguments&.arguments)
        dynamic = arguments.find { |argument| !literal_route_value?(argument) }
        return unless dynamic

        scope_kind, scope_value = dynamic_route_scope(statement, context)
        @route_blockers << route_blocker(
          @current_route_path,
          statement.location.start_line,
          "dynamic route argument for #{statement.name}",
          scope_kind: scope_kind,
          scope_value: scope_value
        )
      end

      def dynamic_route_scope(statement, context)
        controller = literal_route_option(statement, 'controller')
        controller ||= context.controller || context.resource
        if controller
          owner = "#{camelize(route_controller(context, controller))}Controller"
          return [:owner, owner]
        end

        action = literal_route_option(statement, 'action')
        return [:message, action] if action
        return [:namespace, camelize(context.modules.join('/'))] if context.modules.any?

        [:global, '*']
      end

      def literal_route_option(statement, name)
        hash = Array(statement.arguments&.arguments).find do |argument|
          argument.is_a?(Prism::KeywordHashNode) || argument.is_a?(Prism::HashNode)
        end
        pair = Array(hash&.elements).find do |element|
          element.is_a?(Prism::AssocNode) && literal_route_argument(element.key) == name
        end
        literal_route_argument(pair&.value)
      end

      def route_blocker(path, line, reason, scope_kind:, scope_value:)
        Blocker.new(
          kind: :rails_route_dynamic,
          scope_kind: scope_kind,
          scope_value: scope_value,
          source: :rails_rule,
          reason: reason,
          suggested_action: :review_dynamic_route,
          metadata: {
            'caller_domain' => 'runtime',
            'rule_id' => 'rails.route',
            'file' => path,
            'line' => line
          }.compact
        )
      end

      def route_health_blocker(path, line, reason)
        Blocker.new(
          kind: :rails_route_health,
          scope_kind: :global,
          scope_value: '*',
          source: :rails_rule,
          reason: reason,
          suggested_action: :fix_route_source,
          metadata: {
            'caller_domain' => 'runtime',
            'rule_id' => 'rails.route.health',
            'file' => path,
            'line' => line
          }.compact
        )
      end

      def nested_route_context(line, context)
        contexts = [context]
        push_context(contexts, line, context)
        contexts.last
      end

      def route_targets(line, context)
        if (match = line.match(/\broot\s+["']([^#"']+)#([^"']+)["']/))
          return [controller_action_id(route_controller(context, match[1]), match[2])]
        end

        if (match = line.match(/\b(?:#{ROUTE_VERBS.join('|')}|root)\b.*\bto:\s*["']([^#"']+)#([^"']+)["']/))
          return [controller_action_id(route_controller(context, match[1]), match[2])]
        end

        if (target = controller_action_target(line, context))
          return [target]
        end

        if (match = line.match(/\b(?:#{ROUTE_VERBS.join('|')}|root)\b.*=>\s*["']([^#"']+)#([^"']+)["']/))
          return [controller_action_id(route_controller(context, match[1]), match[2])]
        end

        if (match = line.match(/\bmount\s+([A-Z][\w:]+)\s*(?:=>|,\s*at:)/))
          return mounted_engine_targets(match[1])
        end

        if (match = line.match(%r{\b(?:#{ROUTE_VERBS.join('|')})\s+["']/?([a-zA-Z_][\w/]*)/([a-zA-Z_]\w*)["']}))
          return [controller_action_id(route_controller(context, match[1]), match[2])]
        end

        if (match = line.match(/\bresources\s+:([a-zA-Z_]\w*)/))
          controller = resource_controller(line, match[1])
          return resource_actions(line, singular: false).map do |action|
            controller_action_id(route_controller(context, controller), action)
          end
        end

        if (match = line.match(/\bresource\s+:([a-zA-Z_]\w*)/))
          controller = resource_controller(line, pluralize(match[1]))
          return resource_actions(line, singular: true).map do |action|
            controller_action_id(route_controller(context, controller), action)
          end
        end

        if context.resource && (match = line.match(/\b(?:#{ROUTE_VERBS.join('|')})\s+:([a-zA-Z_]\w*)/))
          return [controller_action_id(route_controller(context, context.resource), match[1])]
        end

        if context.controller && (match = line.match(/\b(?:#{ROUTE_VERBS.join('|')})\s+:?["']?([a-zA-Z_]\w*)/))
          return [controller_action_id(route_controller(context, context.controller), match[1])]
        end

        []
      end

      def push_context(contexts, line, context)
        if (match = line.match(/\bnamespace\s+:([a-zA-Z_]\w*)/))
          contexts << RouteContext.new(modules: context.modules + [match[1]], resource: context.resource,
                                       controller: context.controller)
        elsif (match = line.match(/\bscope\b.*\bmodule:\s+:?["']?([a-zA-Z_]\w*)/))
          contexts << RouteContext.new(modules: context.modules + [match[1]], resource: context.resource,
                                       controller: scoped_controller_option(line, context.controller))
        elsif (match = line.match(%r{\bcontroller\s+:?["']?([a-zA-Z_][\w/]*)["']?}))
          contexts << RouteContext.new(modules: context.modules, resource: context.resource, controller: match[1])
        elsif (match = line.match(/\bresources\s+:([a-zA-Z_]\w*)/))
          contexts << RouteContext.new(modules: context.modules, resource: resource_controller(line, match[1]),
                                       controller: context.controller)
        elsif (match = line.match(/\bresource\s+:([a-zA-Z_]\w*)/))
          contexts << RouteContext.new(modules: context.modules,
                                       resource: resource_controller(line, pluralize(match[1])), controller: context.controller)
        elsif line.match?(/\b(?:member|collection|constraints|defaults|scope)\b/)
          contexts << RouteContext.new(modules: context.modules, resource: context.resource,
                                       controller: scoped_controller_option(line, context.controller))
        end
      end

      def route_file_targets(line, project, seen, concerns)
        return [] unless (match = line.match(/\bdraw\s+:?["']?([a-zA-Z_]\w*)/))

        parse_route_file(
          project,
          File.join(project.root, "config/routes/#{match[1]}.rb"),
          seen: seen,
          concerns: concerns
        )
      end

      def concern_targets(line, context, project, seen, concerns)
        target_context = concern_context(line, context)
        concern_names(line).flat_map do |name|
          statements, source = concerns[name]
          next [] unless statements && source

          parse_route_statements(
            statements,
            source: source,
            project: project,
            seen: seen,
            concerns: concerns,
            context: target_context
          )
        end
      end

      def concern_context(line, context)
        if (match = line.match(/\bresources\s+:([a-zA-Z_]\w*)/))
          return RouteContext.new(modules: context.modules, resource: resource_controller(line, match[1]),
                                  controller: context.controller)
        end

        if (match = line.match(/\bresource\s+:([a-zA-Z_]\w*)/))
          return RouteContext.new(modules: context.modules, resource: resource_controller(line, pluralize(match[1])),
                                  controller: context.controller)
        end

        context
      end

      def concern_names(line)
        names = line.scan(/\bconcerns?\s+:([a-zA-Z_]\w*)/).flatten
        names.concat(line.scan(/\bconcerns?:\s+:([a-zA-Z_]\w*)/).flatten)
        if (array_value = line[/\bconcerns?:\s*\[([^\]]+)\]/, 1])
          names.concat(array_value.scan(/:([a-zA-Z_]\w*)/).flatten)
        end
        names.uniq
      end

      def resource_actions(line, singular:)
        return action_option(line, 'only') if line.include?('only:')

        excluded = action_option(line, 'except')
        (singular ? SINGULAR_ACTIONS : RESTFUL_ACTIONS) - excluded
      end

      def action_option(line, name)
        array_value = line[/\b#{name}:\s*(?:\[([^\]]+)\]|%i\[([^\]]+)\])/, 1] ||
                      line[/\b#{name}:\s*(?:\[([^\]]+)\]|%i\[([^\]]+)\])/, 2]
        return array_value.scan(/:?["']?([a-zA-Z_]\w*)["']?/).flatten if array_value

        Array(line[/\b#{name}:\s+:?["']?([a-zA-Z_]\w*)/, 1])
      end

      def resource_controller(line, fallback)
        line[/\bcontroller:\s*["']([^"']+)["']/, 1] || fallback
      end

      def scoped_controller_option(line, fallback)
        line[%r{\bcontroller:\s+:?["']?([a-zA-Z_][\w/]*)}, 1] || fallback
      end

      def scoped_controller(context, controller)
        [*context.modules, controller].join('/')
      end

      def route_controller(context, controller)
        return controller.delete_prefix('/') if controller.start_with?('/')
        return controller if controller.include?('/')

        scoped_controller(context, controller)
      end

      def controller_action_target(line, context)
        controller = literal_source_option(line, 'controller', allow_path: true)
        action = literal_source_option(line, 'action')
        controller ||= context.controller
        return nil unless controller && action

        controller_action_id(route_controller(context, controller), action)
      end

      def literal_source_option(line, name, allow_path: false)
        value_pattern = allow_path ? '[a-zA-Z_][\\w/]*' : '[a-zA-Z_]\\w*'
        match = line.match(/\b#{Regexp.escape(name)}:\s*(?::(#{value_pattern})|["'](#{value_pattern})["'])/)
        match && (match[1] || match[2])
      end

      def mounted_engine_targets(engine_name)
        ["#{engine_name}.call", "#{engine_name}#call"]
      end

      def pluralize(name)
        return IRREGULAR_PLURALS.fetch(name) if IRREGULAR_PLURALS.key?(name)
        return "#{name}es" if name.end_with?('s', 'x', 'z', 'ch', 'sh')
        return "#{name.delete_suffix('y')}ies" if name.match?(/[^aeiou]y\z/)

        "#{name}s"
      end

      def controller_action_id(controller_path, action)
        "#{camelize(controller_path)}Controller##{action}"
      end

      def matching_route_nodes(graph, node_id)
        exact = graph.definitions_for(node_id)
        return exact.select { |node| node.visibility == :public }.map(&:graph_id) unless exact.empty?
        return [] unless node_id.include?('Controller#')

        controller, action = node_id.split('#', 2)
        expected_file = "app/controllers/#{underscore(controller.delete_suffix('Controller'))}_controller.rb"
        graph.method_nodes.filter_map do |node|
          next unless node.name == action && node.owner&.end_with?(controller)
          next unless node.visibility == :public
          next unless node.file == expected_file

          node.graph_id
        end
      end

      def helper_referenced?(project, method_name)
        view_method_names(project).include?(method_name)
      end

      def view_files(project)
        project.reference_files.select do |path|
          project.relative_path(path).start_with?('app/views/', 'app/components/')
        end
      end

      def view_source(path)
        File.read(path)
            .gsub(/<%#.*?%>/m, '')
            .gsub(/<!--.*?-->/m, '')
            .lines.reject { |line| line.strip.start_with?('-#') }.join
      end

      def view_method_names(project)
        @view_method_names ||= {}
        @view_method_names[project.root] ||= view_files(project).each_with_object(Set.new) do |path, names|
          view_source(path).scan(/(?<![A-Za-z0-9_])([a-zA-Z_]\w*[!?=]?)(?![A-Za-z0-9_])/).each do |match|
            names << match.first
          end
        rescue SystemCallError, EncodingError
          next
        end
      end

      def component_entrypoint?(node)
        node.kind == :instance_method && %w[call render? before_render].include?(node.name)
      end

      def camelize(path)
        path.split('/').map { |part| part.split('_').map(&:capitalize).join }.join('::')
      end

      def underscore(constant)
        constant.gsub('::', '/')
                .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
                .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                .downcase
      end
    end
  end
end
