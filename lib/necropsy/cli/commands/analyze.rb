# frozen_string_literal: true

require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Analyze
        def initialize(analysis:, report_emitter:, health:)
          @analysis = analysis
          @report_emitter = report_emitter
          @health = health
        end

        def call(options:, arguments:)
          raise Error, "Unexpected analyze arguments: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options)
          @report_emitter.emit(report: report, options: options, min_confidence: options[:min_confidence])
          return 0 if @health.acceptable?(report: report, options: options, strict: false)

          CLI::HEALTH_FAILURE_STATUS
        end
      end
    end
  end
end
