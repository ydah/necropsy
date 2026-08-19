# frozen_string_literal: true

require_relative '../../reporter'

module Necropsy
  class CLI
    module Commands
      class AnalysisExecutor
        def initialize(analyzer:, self_checker:)
          @analyzer = analyzer
          @self_checker = self_checker
        end

        def call(options:, ignored_reference_paths: [])
          report = @analyzer.analyze(
            root: options[:root],
            config_path: options[:config],
            ignored_reference_paths: ignored_reference_paths,
            as_of: options[:as_of]
          )
          @self_checker.new(report).validate! if options[:self_check]
          report
        end
      end

      class ReportEmitter
        def initialize(reporter: Reporter)
          @reporter = reporter
        end

        def emit(report:, options:, min_confidence:)
          reporter = @reporter.new(report)
          if options[:format] == :ndjson
            reporter.each_ndjson { |line| puts line }
            return
          end

          puts reporter.render(
            format: options[:format],
            min_confidence: min_confidence,
            include_graph: options[:include_graph]
          )
        end

        def with_findings(report, findings)
          Report.new(
            root: report.root,
            graph: report.graph,
            findings: findings,
            reachability: report.reachability,
            project: report.project,
            source_snapshot: report.source_snapshot,
            performance_profile: report.performance_profile,
            analysis_health: report.analysis_health
          )
        end
      end

      class AnalysisHealth
        def initialize(failure_status:, report_emitter:)
          @failure_status = failure_status
          @report_emitter = report_emitter
        end

        def acceptable?(report:, options:, strict:)
          health = report.analysis_health
          return true if health.complete?

          allowed = Array(options[:allow_degraded])
          degraded_codes = health.reasons.filter_map do |reason|
            reason['code'].to_s if reason['severity'].to_s == 'degraded'
          end.uniq
          explicitly_allowed = health.status == :degraded && degraded_codes.any? &&
                               (degraded_codes - allowed).empty?
          return true if explicitly_allowed

          !(strict || options[:strict_health])
        end

        def failure(report:, options:)
          if options[:format] == :human
            puts Reporter.render_analysis_health(report.analysis_health)
          else
            @report_emitter.emit(report: report, options: options, min_confidence: :low)
          end
          @failure_status
        end
      end
    end
  end
end
