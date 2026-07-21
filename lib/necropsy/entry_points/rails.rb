# frozen_string_literal: true

module Necropsy
  module EntryPoints
    class Rails
      ROUTE_VERBS = %w[get post put patch delete match].freeze
      RESTFUL_ACTIONS = %w[index show new create edit update destroy].freeze
      SINGULAR_ACTIONS = %w[show new create edit update destroy].freeze
      IRREGULAR_PLURALS = { 'person' => 'people', 'man' => 'men', 'woman' => 'women', 'child' => 'children' }.freeze
      RouteContext = Struct.new(:modules, :resource, :controller, keyword_init: true)

      def apply(graph, project)
        return unless project.config.rails_enabled?

        referenced_view_methods = view_method_names(project)
        graph.method_nodes.each do |node|
          case node.file
          when %r{\Aapp/jobs/}
            graph.add_entry_point(node.id, :job_perform) if node.name == 'perform'
          when %r{\Aapp/mailers/}
            graph.add_entry_point(node.id, :mailer_action) if node.kind == :instance_method && node.visibility == :public
          when %r{\Aapp/helpers/}
            graph.add_entry_point(node.id, :rails_view_helper) if referenced_view_methods.include?(node.name)
          when %r{\Aapp/components/}
            graph.add_entry_point(node.id, :rails_component) if component_entrypoint?(node)
          when %r{\Adb/migrate/}
            graph.add_entry_point(node.id, :rails_migration) if %w[change up down].include?(node.name)
          end


          if node.file.start_with?('app/') && !node.file.start_with?('app/helpers/', 'app/components/') &&
             referenced_view_methods.include?(node.name)
            graph.add_entry_point(node.id, :rails_view_reference)
          end
        end

        graph.nodes.values.select do |node|
          node.kind == :block_entry && node.file.start_with?('config/initializers/')
        end.each do |node|
          graph.add_entry_point(node.id, :callback_registered)
        end

        route_entry_points(project).each do |node_id|
          matching_route_nodes(graph, node_id).each do |matching_id|
            graph.add_entry_point(matching_id, :rails_route)
          end
        end
      end

      private

      def route_entry_points(project)
        routes = File.join(project.root, 'config/routes.rb')
        parse_route_file(project.root, routes, seen: {}, concerns: {})
      end

      def parse_route_file(root, path, seen:, concerns:)
        expanded = File.expand_path(path, root)
        return [] unless File.exist?(expanded)
        return [] if seen[expanded]

        seen[expanded] = true
        parse_routes(File.readlines(expanded), root: root, seen: seen, concerns: concerns)
      end

      def parse_routes(lines, root:, seen:, concerns:, initial_context: RouteContext.new(modules: [], resource: nil))
        contexts = [initial_context]
        capture = nil
        targets = []

        lines.each do |line|
          stripped = strip_route_comment(line).strip
          next if stripped.empty?

          if capture
            capture[:depth] += block_openings(stripped)
            capture[:depth] -= 1 if stripped == 'end'

            if capture[:depth].zero?
              concerns[capture[:name]] = capture[:lines]
              capture = nil
            else
              capture[:lines] << stripped
            end
            next
          end

          if (match = stripped.match(/\bconcern\s+:([a-zA-Z_]\w*)\s+do\b/))
            capture = { name: match[1], depth: 1, lines: [] }
            next
          end

          if stripped == 'end'
            contexts.pop if contexts.length > 1
            next
          end

          context = contexts.last
          targets.concat(route_targets(stripped, context))
          targets.concat(route_file_targets(stripped, root, seen, concerns))
          targets.concat(concern_targets(stripped, context, root, seen, concerns))
          push_context(contexts, stripped, context)
        end

        targets.compact.uniq
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
        elsif (match = line.match(%r{\bcontroller\s+:?["']?([a-zA-Z_][\w/]*)["']?\s+do\b}))
          contexts << RouteContext.new(modules: context.modules, resource: context.resource, controller: match[1])
        elsif line.match?(/\bscope\b.*\bcontroller:\s*.*do\b/)
          contexts << RouteContext.new(modules: context.modules, resource: context.resource,
                                       controller: scoped_controller_option(line, context.controller))
        elsif (match = line.match(/\bresources\s+:([a-zA-Z_]\w*).*do\b/))
          contexts << RouteContext.new(modules: context.modules, resource: resource_controller(line, match[1]),
                                       controller: context.controller)
        elsif (match = line.match(/\bresource\s+:([a-zA-Z_]\w*).*do\b/))
          contexts << RouteContext.new(modules: context.modules,
                                       resource: resource_controller(line, pluralize(match[1])), controller: context.controller)
        elsif line.match?(/\b(?:member|collection)\s+do\b/)
          contexts << RouteContext.new(modules: context.modules, resource: context.resource,
                                       controller: context.controller)
        elsif line.match?(/\b(?:constraints|defaults|scope)\b.*do\b/)
          contexts << RouteContext.new(modules: context.modules, resource: context.resource,
                                       controller: scoped_controller_option(line, context.controller))
        end
      end

      def route_file_targets(line, root, seen, concerns)
        return [] unless (match = line.match(/\bdraw\s+:?["']?([a-zA-Z_]\w*)/))

        parse_route_file(root, File.join(root, "config/routes/#{match[1]}.rb"), seen: seen, concerns: concerns)
      end

      def concern_targets(line, context, root, seen, concerns)
        target_context = concern_context(line, context)
        concern_names(line).flat_map do |name|
          parse_routes(concerns.fetch(name, []), root: root, seen: seen, concerns: concerns,
                                                 initial_context: target_context)
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
        return array_value.scan(/:?["']?([a-zA-Z_]\w*)["']?/) if array_value

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
        controller = line[%r{\bcontroller:\s+:?["']?([a-zA-Z_][\w/]*)}, 1]
        action = line[/\baction:\s+:?["']?([a-zA-Z_]\w*)/, 1]
        controller ||= context.controller
        return nil unless controller && action

        controller_action_id(route_controller(context, controller), action)
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
        graph.nodes.key?(node_id) ? [node_id] : []
      end

      def helper_referenced?(project, method_name)
        view_method_names(project).include?(method_name)
      end

      def view_files(project)
        Dir.glob(File.join(project.root, '{app/views,app/components}/**/*')).select { |path| File.file?(path) }
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

      def block_openings(line)
        line.scan(/\bdo\b/).length
      end

      def strip_route_comment(line)
        quote = nil
        escaped = false
        line.each_char.with_index do |char, index|
          if escaped
            escaped = false
            next
          end

          if char == '\\'
            escaped = true
            next
          end

          if quote
            quote = nil if char == quote
            next
          end

          quote = char if ["'", '"'].include?(char)
          return line[0...index] if char == '#'
        end

        line
      end
    end
  end
end
