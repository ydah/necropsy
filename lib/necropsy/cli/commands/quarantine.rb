# frozen_string_literal: true

require_relative '../../guardrail/quarantine'
require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Quarantine
        def initialize(analysis:, health:, clock:)
          @analysis = analysis
          @health = health
          @clock = clock
        end

        def call(options:, arguments:)
          raise Error, "Unexpected quarantine arguments: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options)
          return @health.failure(report: report, options: options) unless
            @health.acceptable?(report: report, options: options, strict: options[:write])

          quarantine = Guardrail::Quarantine.new(
            report: report,
            root: File.expand_path(options[:root]),
            clock: @clock.new(as_of: options[:as_of])
          )
          if options[:write]
            quarantine.write(min_confidence: options[:min_confidence])
            puts 'Wrote quarantine annotations'
          else
            quarantine.suggestions(min_confidence: options[:min_confidence]).each do |suggestion|
              finding = suggestion[:finding]
              puts "#{suggestion[:path]}:#{suggestion[:line]} #{suggestion[:annotation]} #{finding.node.id}"
            end
          end
          0
        end
      end
    end
  end
end
