# frozen_string_literal: true

require_relative '../../guardrail/baseline'
require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Baseline
        def initialize(analysis:, health:, baseline:, clock:)
          @analysis = analysis
          @health = health
          @baseline = baseline
          @clock = clock
        end

        def call(options:, arguments:)
          migration = arguments.first == 'migrate'
          arguments.shift if migration
          raise Error, "Unexpected baseline arguments: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options, ignored_reference_paths: [options[:baseline]])
          return @health.failure(report: report, options: options) unless @health.acceptable?(report: report, options: options, strict: true)

          path = File.expand_path(options[:baseline], options[:root])
          return 1 if migration && migrate_baseline(report, path)

          @baseline.write(report, path: path, clock: @clock.new(as_of: options[:as_of]))
          puts "#{migration ? 'Migrated' : 'Wrote'} #{path}"
          0
        end

        private

        def migrate_baseline(report, path)
          comparison = @baseline.load(path).migrate(report.actionable_candidates(min_confidence: :low))
          return unless comparison.review_required?

          puts Reporter.render_baseline_review(comparison.review_report)
          true
        end
      end
    end
  end
end
