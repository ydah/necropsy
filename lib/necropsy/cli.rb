# frozen_string_literal: true

require 'date'
require 'digest'
require 'English'
require 'fileutils'
require 'json'
require 'optparse'
require 'rbconfig'
require 'securerandom'
require 'yaml'
require 'necropsy'

module Necropsy
  class CLI
    HEALTH_FAILURE_STATUS = 3

    def self.run(argv)
      new.run(argv)
    end

    def initialize(run_id_generator: nil, environment: ENV)
      @run_id_generator = run_id_generator
      @environment = environment
    end

    def run(argv)
      require_relative 'reporter'

      command = argv.first&.start_with?('-') ? 'analyze' : argv.shift || 'analyze'
      options = default_options
      parser = build_parser(options)
      parser.parse!(argv)
      if options[:help]
        puts parser
        return 0
      end
      if options[:version]
        puts Necropsy::VERSION
        return 0
      end
      apply_config_defaults(options) unless command == 'semantics'

      case command
      when 'analyze'
        report = analyze(options)
        emit_report(report, options, min_confidence: options[:min_confidence])
        health_acceptable?(report, options, strict: false) ? 0 : HEALTH_FAILURE_STATUS
      when 'baseline'
        baseline(options, argv)
      when 'check'
        check(options)
      when 'quarantine'
        quarantine(options)
      when 'bench'
        bench(options)
      when 'record'
        record(options, argv)
      when 'coverage'
        coverage(options, argv)
      when 'semantics'
        semantics(options, argv)
      when 'doctor'
        doctor(options)
      when 'feedback'
        feedback(options, argv)
      when 'diff'
        causal_diff(options)
      when 'plan', 'patch', 'verify'
        removal_workflow(command, options, argv)
      when 'why', 'why-not', 'explain'
        diagnose(command, options, argv)
      else
        warn "Unknown command: #{command}"
        warn parser
        2
      end
    rescue OptionParser::ParseError, Psych::Exception, Error, GraphSelfCheck::Failure,
           ArgumentError, TypeError, KeyError => e
      warn e.message
      2
    end

    private

    def default_options
      {
        root: '.',
        config: nil,
        format: :human,
        min_confidence: Reporter::DEFAULT_MIN_CONFIDENCE,
        baseline: nil,
        fail_on: nil,
        diff_base: nil,
        ratchet: false,
        write: false,
        gold_standard: nil,
        output: nil,
        sample_rate: 1.0,
        ablation: false,
        bench_check: false,
        precision_threshold: nil,
        recall_threshold: nil,
        as_of: nil,
        strict_health: false,
        allow_degraded: [],
        help: false,
        version: false,
        include_graph: false,
        self_check: false,
        report: nil,
        observed: nil,
        candidate: nil,
        max_fixtures: RuntimeFeedback::DEFAULT_FIXTURE_LIMIT,
        fail_on_missing_static_target: false,
        base_report: nil,
        head_report: nil,
        verify_timeout: default_verify_timeout
      }
    end

    def build_parser(options)
      OptionParser.new do |parser|
        parser.banner = 'Usage: necropsy COMMAND [options]'
        parser.on('--root PATH', 'Project root') { |value| options[:root] = value }
        parser.on('--config PATH', 'Configuration file') { |value| options[:config] = value }
        parser.on('--format FORMAT', Reporter::FORMATS.map(&:to_s), 'Output format') do |value|
          options[:format] = value.to_sym
        end
        parser.on('--include-graph', 'Include nodes and edges in JSON/YAML output') { options[:include_graph] = true }
        parser.on('--self-check', 'Validate graph invariants after analysis') { options[:self_check] = true }
        parser.on('--min-confidence LEVEL', 'low, medium, high, or certain') do |value|
          options[:min_confidence] = confidence_level(value)
        end
        parser.on('--baseline PATH', 'Baseline path') { |value| options[:baseline] = value }
        parser.on('--fail-on LEVEL', 'CI failure threshold') do |value|
          options[:fail_on] = ci_threshold(value)
        end
        parser.on('--diff-base REV', 'Restrict reported findings to files changed since REV') do |value|
          options[:diff_base] = value
        end
        parser.on('--ratchet', 'Fail if finding count grows beyond baseline count') { options[:ratchet] = true }
        parser.on('--write', 'Write quarantine annotations') { options[:write] = true }
        parser.on('--gold-standard PATH', 'Gold standard YAML for bench') { |value| options[:gold_standard] = value }
        parser.on('--output PATH', 'Output path for record') { |value| options[:output] = value }
        parser.on('--report PATH', 'Static report or proof report path') { |value| options[:report] = value }
        parser.on('--observed PATH', 'Runtime observed-target artifact path') { |value| options[:observed] = value }
        parser.on('--candidate ID', 'Physical definition ID or unique symbol ID') { |value| options[:candidate] = value }
        parser.on('--max-fixtures N', Integer, 'Maximum exported runtime feedback fixtures') do |value|
          raise OptionParser::InvalidArgument, 'max-fixtures must be non-negative' if value.negative?

          options[:max_fixtures] = value
        end
        parser.on('--fail-on-missing-static-target', 'Fail feedback verification on a missing static target') do
          options[:fail_on_missing_static_target] = true
        end
        parser.on('--base PATH_OR_REVISION', 'Base report path or Git revision for causal diff') do |value|
          options[:base_report] = value
        end
        parser.on('--head PATH_OR_REVISION', 'Head report path or Git revision for causal diff') do |value|
          options[:head_report] = value
        end
        parser.on('--verify-timeout SECONDS', Float, 'Maximum removal verification time') do |value|
          raise OptionParser::InvalidArgument, 'verify-timeout must be positive and finite' unless value.positive? && value.finite?

          options[:verify_timeout] = value
        end
        parser.on('--sample-rate RATE', Float, 'TracePoint sample rate for record') do |value|
          raise OptionParser::InvalidArgument, 'sample rate must be between 0.0 and 1.0' unless value.between?(0.0, 1.0)

          options[:sample_rate] = value
        end
        parser.on('--ablation', 'Run bench across analyzer combinations') { options[:ablation] = true }
        parser.on('--check', 'Fail bench when release criteria do not pass') { options[:bench_check] = true }
        parser.on('--precision-threshold N', Float, 'Bench release precision threshold') do |value|
          options[:precision_threshold] = value
        end
        parser.on('--recall-threshold N', Float, 'Bench release recall threshold') do |value|
          options[:recall_threshold] = value
        end
        parser.on('--as-of DATE', 'Use a reproducible UTC date for time-dependent analysis') do |value|
          options[:as_of] = Date.iso8601(value)
        rescue Date::Error
          raise OptionParser::InvalidArgument, 'as-of must be an ISO 8601 date'
        end
        parser.on('--strict-health', 'Return status 3 unless analysis health is complete') do
          options[:strict_health] = true
        end
        parser.on('--allow-degraded=REASONS', 'Comma-separated degraded reason codes to allow explicitly') do |value|
          reasons = value.split(',').map(&:strip).reject(&:empty?)
          raise OptionParser::InvalidArgument, 'allow-degraded requires at least one reason code' if reasons.empty?
          unless reasons.all? { |reason| reason.match?(/\A[a-z][a-z0-9_]*\z/) }
            raise OptionParser::InvalidArgument, 'allow-degraded reason codes must use lowercase letters, numbers, and _'
          end

          options[:allow_degraded] |= reasons
        end
        parser.on('-h', '--help', 'Show help') do
          options[:help] = true
        end
        parser.on('-v', '--version', 'Show version') { options[:version] = true }
      end
    end

    def default_verify_timeout
      require_relative 'removal_workflow'

      RemovalWorkflow::DEFAULT_TIMEOUT_SECONDS
    end

    def analyze(options, ignored_reference_paths: [])
      report = Necropsy.analyze(
        root: options[:root],
        config_path: options[:config],
        ignored_reference_paths: ignored_reference_paths,
        as_of: options[:as_of]
      )
      GraphSelfCheck.new(report).validate! if options[:self_check]
      report
    end

    def diagnose(command, options, argv)
      require_relative 'diagnostics'

      node_id = argv.shift
      raise Error, "#{command} requires a symbol or definition ID" unless node_id
      raise Error, "Unexpected arguments for #{command}: #{argv.join(' ')}" unless argv.empty?

      report = analyze(options)
      return health_failure(report, options) unless health_acceptable?(report, options, strict: false)

      diagnostics = Diagnostics.new(report)
      payload = case command
                when 'why' then diagnostics.why(node_id)
                when 'why-not' then diagnostics.why_not(node_id)
                else diagnostics.explain(node_id)
                end
      puts diagnostics.render(payload, format: options[:format])
      0
    end

    def apply_config_defaults(options)
      config = Configuration.load(root: File.expand_path(options[:root]), path: options[:config])
      options[:baseline] ||= config.baseline_path
      options[:fail_on] ||= config.fail_on
    end

    def check(options)
      require_relative 'guardrail/baseline'

      report = analyze(options, ignored_reference_paths: [options[:baseline]])
      return health_failure(report, options) unless health_acceptable?(report, options, strict: true)

      report_invalid_quarantine_dates(report)
      expiry_failure = apply_quarantine_expiry_policy(report, report_config(options))
      findings = filtered_findings(report, options)
      baseline_path = File.expand_path(options[:baseline], options[:root])
      baseline = Guardrail::Baseline.load(baseline_path)
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
        emit_report(report_with_findings(report, failures), options, min_confidence: :low)
        return 1
      end

      return 1 if expiry_failure

      puts 'Necropsy check passed'
      0
    end

    def report_with_findings(report, findings)
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

    def emit_report(report, options, min_confidence:)
      reporter = Reporter.new(report)
      if options[:format] == :ndjson
        reporter.each_ndjson { |line| puts line }
      else
        puts reporter.render(
          format: options[:format],
          min_confidence: min_confidence,
          include_graph: options[:include_graph]
        )
      end
    end

    def semantics(options, argv)
      raise Error, "Unexpected semantics arguments: #{argv.join(' ')}" unless argv.empty?

      puts SemanticsMatrix.new.render(format: options[:format])
      0
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
      findings = findings_with_quarantine_component(report, 'quarantine_invalid_date')
      return if findings.empty?

      noun = findings.length == 1 ? 'annotation has' : 'annotations have'
      lines = findings.map { |finding| "  #{finding.node.file}:#{finding.node.line} #{finding.node.id}" }
      warn "Invalid quarantine date warning: #{findings.length} #{noun} an invalid since date\n#{lines.join("\n")}"
    end

    def findings_with_quarantine_component(report, name)
      findings_with_quarantine_components(report, [name])
    end

    def findings_with_quarantine_components(report, names)
      report.dead_methods(min_confidence: :low).select do |finding|
        finding.score_components.any? { |component| names.include?(component.name) }
      end
    end

    def filtered_findings(report, options)
      threshold = options[:fail_on]
      findings = if actionability_threshold?(threshold)
                   report.actionable_candidates(min_actionability: actionability_threshold(threshold))
                 else
                   report.actionable_candidates(min_confidence: threshold)
                 end
      return findings unless options[:diff_base]

      project = Project.new(root: File.expand_path(options[:root]), config: report_config(options))
      changed = project.changed_files(options[:diff_base])
      findings.select { |finding| changed.include?(finding.node.file) }
    end

    def report_config(options)
      Configuration.load(root: File.expand_path(options[:root]), path: options[:config])
    end

    def health_failure(report, options)
      if options[:format] == :human
        puts Reporter.render_analysis_health(report.analysis_health)
      else
        emit_report(report, options, min_confidence: :low)
      end
      HEALTH_FAILURE_STATUS
    end

    def health_acceptable?(report, options, strict:)
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

    def baseline(options, argv)
      require_relative 'guardrail/baseline'

      migration = argv.first == 'migrate'
      argv.shift if migration
      raise Error, "Unexpected baseline arguments: #{argv.join(' ')}" unless argv.empty?

      report = analyze(options, ignored_reference_paths: [options[:baseline]])
      return health_failure(report, options) unless health_acceptable?(report, options, strict: true)

      path = File.expand_path(options[:baseline], options[:root])
      if migration
        comparison = Guardrail::Baseline.load(path).migrate(report.actionable_candidates(min_confidence: :low))
        if comparison.review_required?
          puts Reporter.render_baseline_review(comparison.review_report)
          return 1
        end
      end
      Guardrail::Baseline.write(report, path: path, clock: Clock.new(as_of: options[:as_of]))
      puts "#{migration ? 'Migrated' : 'Wrote'} #{path}"
      0
    end

    def quarantine(options)
      require_relative 'guardrail/quarantine'

      report = analyze(options)
      return health_failure(report, options) unless health_acceptable?(report, options, strict: options[:write])

      quarantine = Guardrail::Quarantine.new(
        report: report,
        root: File.expand_path(options[:root]),
        clock: Clock.new(as_of: options[:as_of])
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

    def bench(options)
      require_relative 'bench/evaluator'

      raise Error, '--gold-standard is required for bench' unless options[:gold_standard]

      gold_standard_path = File.expand_path(options[:gold_standard])
      report = analyze(options, ignored_reference_paths: [gold_standard_path])
      return health_failure(report, options) unless health_acceptable?(report, options, strict: true)

      config = report_config(options)
      result = Bench::Evaluator.new(
        report: report,
        gold_standard_path: gold_standard_path,
        min_confidence: options[:min_confidence],
        root: options[:root],
        config_path: options[:config],
        ablation: options[:ablation],
        precision_threshold: options[:precision_threshold] || config.bench_precision_threshold,
        recall_threshold: options[:recall_threshold] || config.bench_recall_threshold
      ).call
      puts JSON.pretty_generate(result)
      options[:bench_check] && !result.dig('release_criteria', 'passed') ? 1 : 0
    end

    def doctor(options)
      require_relative 'doctor'

      report = analyze(options)
      config = report_config(options)
      doctor = Doctor.new(report: report, config: config)
      puts doctor.render(format: options[:format])
      result = doctor.call
      return 1 if result.fetch('status') == 'error'

      result.fetch('checks').any? { |check| check.fetch('status') == 'issue' } ? 1 : 0
    end

    def feedback(options, argv)
      require_relative 'feedback_workflow'

      subcommand = argv.shift || 'compare'
      raise Error, 'feedback requires --report and --observed' unless options[:report] && options[:observed]
      raise Error, "Unexpected feedback arguments: #{argv.join(' ')}" unless argv.empty?

      workflow = FeedbackWorkflow.new(
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

    def causal_diff(options)
      require_relative 'guardrail/diff'

      raise Error, 'diff requires --base' unless options[:base_report]

      base_path = File.expand_path(options[:base_report], options[:root])
      head_path = options[:head_report] && File.expand_path(options[:head_report], options[:root])
      result = if head_path && File.file?(base_path) && File.file?(head_path)
                 Guardrail::Diff.compare_reports(base_path: base_path, head_path: head_path)
               elsif !options[:head_report] && !File.file?(base_path)
                 Guardrail::Diff.compare_revisions(
                   root: options[:root], base_revision: options[:base_report], config_path: options[:config]
                 )
               elsif options[:head_report] && !File.file?(base_path) && !File.file?(head_path)
                 Guardrail::Diff.compare_revisions(
                   root: options[:root], base_revision: options[:base_report],
                   head_revision: options[:head_report], config_path: options[:config]
                 )
               else
                 raise Error, 'diff expects two report paths or one/two Git revisions'
               end
      puts JSON.pretty_generate(result)
      0
    end

    def removal_workflow(command, options, argv)
      require_relative 'removal_workflow'

      raise Error, "#{command} requires --report and --candidate" unless options[:report] && options[:candidate]

      workflow = RemovalWorkflow.new(report_path: options[:report], candidate: options[:candidate],
                                     root: File.expand_path(options[:root]), timeout_seconds: options[:verify_timeout])
      case command
      when 'plan'
        result = workflow.plan
        write_or_print(result, options[:output], root: options[:root])
        0
      when 'patch'
        result = workflow.patch_preview
        write_or_print(result, options[:output], root: options[:root], raw: true)
        0
      when 'verify'
        raise Error, 'verify requires a command after --' if argv.empty?

        result = workflow.verify(argv)
        puts JSON.pretty_generate(result)
        result.fetch('passed') ? 0 : 1
      end
    end

    def write_or_print(value, path, root:, raw: false)
      contents = raw ? value : JSON.pretty_generate(value)
      if path
        destination = File.expand_path(path, root)
        FileUtils.mkdir_p(File.dirname(destination))
        File.write(destination, "#{contents}\n")
        puts "Wrote #{destination}"
      else
        puts contents
      end
    end

    def record(options, argv)
      runtime_evidence.record(options, argv)
    end

    def coverage(options, argv)
      runtime_evidence.coverage(options, argv)
    end

    def confidence_level(value)
      level = value.to_sym
      return level if CONFIDENCE_LEVELS.key?(level)

      raise OptionParser::InvalidArgument, "unknown confidence level: #{value}"
    end

    def ci_threshold(value)
      threshold = value.to_sym
      return threshold if CONFIDENCE_LEVELS.key?(threshold) ||
                          Configuration::CI_ACTIONABILITY_THRESHOLDS.include?(threshold)

      allowed = (CONFIDENCE_LEVELS.keys + Configuration::CI_ACTIONABILITY_THRESHOLDS).join(', ')
      raise OptionParser::InvalidArgument, "unknown CI threshold: #{value}; expected one of: #{allowed}"
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

    def artifact_run_id(options, output, kind)
      runtime_evidence.artifact_run_id(options, output, kind)
    end

    def runtime_evidence
      @runtime_evidence ||= CLI::RuntimeEvidence.new(
        run_id_generator: @run_id_generator,
        environment: @environment
      )
    end
  end
end

require_relative 'cli/runtime_evidence'
