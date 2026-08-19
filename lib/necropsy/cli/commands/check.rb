# frozen_string_literal: true

require_relative '../../project'
require_relative '../../guardrail/baseline'
require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Check
        def initialize(analysis:, report_emitter:, health:, baseline:, configuration:)
          @analysis = analysis
          @report_emitter = report_emitter
          @health = health
          @baseline = baseline
          @configuration = configuration
        end

        def call(options:, arguments:)
          raise Error, "Unexpected check arguments: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options, ignored_reference_paths: [options[:baseline]])
          return @health.failure(report: report, options: options) unless @health.acceptable?(report: report, options: options, strict: true)

          report_invalid_quarantine_dates(report)
          config = configuration(options)
          expiry_failure = apply_quarantine_expiry_policy(report, config)
          findings = filtered_findings(report, options, config)
          baseline_path = File.expand_path(options[:baseline], options[:root])
          baseline = @baseline.load(baseline_path)
          comparison = baseline.compare(report.actionable_candidates(min_confidence: :low))
          if comparison.review_required?
            puts Reporter.render_baseline_review(comparison.review_report)
            return 1
          end
          failures = findings - comparison.matched_findings

          baseline_count = baseline.count_at_least(options[:fail_on])
          if options[:ratchet] && findings.length > baseline_count
            puts "Ratchet failed: #{findings.length} findings exceed baseline count #{baseline_count}"
            return 1
          end

          if failures.any?
            @report_emitter.emit(
              report: @report_emitter.with_findings(report, failures), options: options, min_confidence: :low
            )
            return 1
          end

          return 1 if expiry_failure

          puts 'Necropsy check passed'
          0
        end

        private

        def configuration(options)
          @configuration.load(root: File.expand_path(options[:root]), path: options[:config])
        end

        def filtered_findings(report, options, config)
          threshold = options[:fail_on]
          findings = if actionability_threshold?(threshold)
                       report.actionable_candidates(min_actionability: actionability_threshold(threshold))
                     else
                       report.actionable_candidates(min_confidence: threshold)
                     end
          return findings unless options[:diff_base]

          project = Project.new(root: File.expand_path(options[:root]), config: config)
          changed = project.changed_files(options[:diff_base])
          findings.select { |finding| changed.include?(finding.node.file) }
        end

        def actionability_threshold?(threshold)
          Configuration::CI_ACTIONABILITY_THRESHOLDS.include?(threshold)
        end

        def actionability_threshold(threshold)
          case threshold
          when :new_review_candidate then :review_candidate
          when :new_verified_candidate then :verified_candidate
          else raise Error, "Unsupported actionability threshold: #{threshold}"
          end
        end

        def apply_quarantine_expiry_policy(report, config)
          policy = config.quarantine_expiry
          return false if policy == :ignore

          findings = findings_with_quarantine_components(
            report,
            %w[quarantine_review_required quarantine_fingerprint_required quarantine_stale_fingerprint]
          )
          return false if findings.empty?

          noun = findings.length == 1 ? 'annotation requires' : 'annotations require'
          lines = findings.map { |finding| "  #{finding.node.file}:#{finding.node.line} #{finding.node.id}" }
          message = "Quarantine expiry #{policy == :fail ? 'failed' : 'warning'}: " \
                    "#{findings.length} #{noun} review\n#{lines.join("\n")}"
          if policy == :warn
            warn message
            return false
          end

          puts message
          true
        end

        def report_invalid_quarantine_dates(report)
          findings = findings_with_quarantine_components(report, ['quarantine_invalid_date'])
          return if findings.empty?

          noun = findings.length == 1 ? 'annotation has' : 'annotations have'
          lines = findings.map { |finding| "  #{finding.node.file}:#{finding.node.line} #{finding.node.id}" }
          warn "Invalid quarantine date warning: #{findings.length} #{noun} an invalid since date\n#{lines.join("\n")}"
        end

        def findings_with_quarantine_components(report, names)
          report.dead_methods(min_confidence: :low).select do |finding|
            finding.score_components.any? { |component| names.include?(component.name) }
          end
        end
      end
    end
  end
end
