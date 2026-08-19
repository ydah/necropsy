# frozen_string_literal: true

require_relative '../../diagnostics'
require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Diagnostics
        def initialize(analysis:, health:, diagnostics:, command:)
          @analysis = analysis
          @health = health
          @diagnostics_class = diagnostics
          @command = command
        end

        def call(options:, arguments:)
          node_id = arguments.shift
          raise Error, "#{@command} requires a symbol or definition ID" unless node_id
          raise Error, "Unexpected arguments for #{@command}: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options)
          return @health.failure(report: report, options: options) unless
            @health.acceptable?(report: report, options: options, strict: false)

          diagnostics = @diagnostics_class.new(report)
          payload = case @command
                    when 'why' then diagnostics.why(node_id)
                    when 'why-not' then diagnostics.why_not(node_id)
                    else diagnostics.explain(node_id)
                    end
          puts diagnostics.render(payload, format: options[:format])
          0
        end
      end
    end
  end
end
