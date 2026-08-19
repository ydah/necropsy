# frozen_string_literal: true

require 'json'
require_relative '../../feedback_workflow'

module Necropsy
  class CLI
    module Commands
      class Feedback
        def initialize(workflow:)
          @workflow_class = workflow
        end

        def call(options:, arguments:)
          subcommand = arguments.shift || 'compare'
          raise Error, 'feedback requires --report and --observed' unless options[:report] && options[:observed]
          raise Error, "Unexpected feedback arguments: #{arguments.join(' ')}" unless arguments.empty?

          workflow = @workflow_class.new(
            static_report: options[:report],
            observed_artifact: options[:observed],
            max_fixtures: options[:max_fixtures]
          )
          result = case subcommand
                   when 'compare' then workflow.compare
                   when 'export-fixtures'
                     raise Error, 'feedback export-fixtures requires --output' unless options[:output]

                     workflow.export_fixtures(options[:output])
                   when 'verify'
                     workflow.verify(fail_on_missing_static_target: options[:fail_on_missing_static_target])
                   else
                     raise Error, "Unknown feedback command: #{subcommand}"
                   end
          puts JSON.pretty_generate(result)
          return 1 if subcommand == 'verify' && !result.dig('verification', 'passed')

          0
        end
      end
    end
  end
end
