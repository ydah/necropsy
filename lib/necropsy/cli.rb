# frozen_string_literal: true

require 'date'
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
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
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
      apply_config_defaults(options)

      case command
      when 'analyze'
        report = analyze(options)
        puts Reporter.new(report).render(
          format: options[:format],
          min_confidence: options[:min_confidence],
          include_graph: options[:include_graph]
        )
        0
      when 'baseline'
        report = analyze(options)
        path = File.expand_path(options[:baseline], options[:root])
        Guardrail::Baseline.write(report, path: path)
        puts "Wrote #{path}"
        0
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
      when 'why', 'explain'
        diagnose(command, options, argv)
      else
        warn "Unknown command: #{command}"
        warn parser
        2
      end
    rescue OptionParser::ParseError, Psych::Exception, Error => e
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
        precision_threshold: nil,
        recall_threshold: nil,
        help: false,
        version: false,
        include_graph: false
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
        parser.on('--min-confidence LEVEL', 'low, medium, high, or certain') do |value|
          options[:min_confidence] = confidence_level(value)
        end
        parser.on('--baseline PATH', 'Baseline path') { |value| options[:baseline] = value }
        parser.on('--fail-on LEVEL', 'CI failure threshold') do |value|
          options[:fail_on] = confidence_level(value)
        end
        parser.on('--diff-base REV', 'Restrict reported findings to files changed since REV') do |value|
          options[:diff_base] = value
        end
        parser.on('--ratchet', 'Fail if finding count grows beyond baseline count') { options[:ratchet] = true }
        parser.on('--write', 'Write quarantine annotations') { options[:write] = true }
        parser.on('--gold-standard PATH', 'Gold standard YAML for bench') { |value| options[:gold_standard] = value }
        parser.on('--output PATH', 'Output path for record') { |value| options[:output] = value }
        parser.on('--sample-rate RATE', Float, 'TracePoint sample rate for record') do |value|
          raise OptionParser::InvalidArgument, 'sample rate must be between 0.0 and 1.0' unless value.between?(0.0, 1.0)

          options[:sample_rate] = value
        end
        parser.on('--ablation', 'Run bench across analyzer combinations') { options[:ablation] = true }
        parser.on('--precision-threshold N', Float, 'Bench release precision threshold') do |value|
          options[:precision_threshold] = value
        end
        parser.on('--recall-threshold N', Float, 'Bench release recall threshold') do |value|
          options[:recall_threshold] = value
        end
        parser.on('-h', '--help', 'Show help') do
          options[:help] = true
        end
        parser.on('-v', '--version', 'Show version') { options[:version] = true }
      end
    end

    def analyze(options)
      Necropsy.analyze(root: options[:root], config_path: options[:config])
    end

    def diagnose(command, options, argv)
      node_id = argv.shift
      raise Error, "#{command} requires a symbol or definition ID" unless node_id
      raise Error, "Unexpected arguments for #{command}: #{argv.join(' ')}" unless argv.empty?

      diagnostics = Diagnostics.new(analyze(options))
      payload = command == 'why' ? diagnostics.why(node_id) : diagnostics.explain(node_id)
      puts diagnostics.render(payload, format: options[:format])
      0
    end

    def apply_config_defaults(options)
      config = Configuration.load(root: File.expand_path(options[:root]), path: options[:config])
      options[:baseline] ||= config.baseline_path
      options[:fail_on] ||= config.fail_on
    end

    def check(options)
      report = analyze(options)
      report_invalid_quarantine_dates(report)
      expiry_failure = apply_quarantine_expiry_policy(report, report_config(options))
      findings = filtered_findings(report, options)
      baseline_path = File.expand_path(options[:baseline], options[:root])
      baseline = Guardrail::Baseline.load(baseline_path)
      failures = findings.reject { |finding| baseline.include?(finding) }

      baseline_count = baseline.count_at_least(options[:fail_on])
      if options[:ratchet] && findings.length > baseline_count
        puts "Ratchet failed: #{findings.length} findings exceed baseline count #{baseline_count}"
        return 1
      end

      if failures.any?
        puts Reporter.new(Report.new(root: report.root, graph: report.graph, findings: failures)).render(
          format: :human,
          min_confidence: options[:fail_on]
        )
        return 1
      end

      return 1 if expiry_failure

      puts 'Necropsy check passed'
      0
    end

    def apply_quarantine_expiry_policy(report, config)
      policy = config.quarantine_expiry
      return false if policy == :ignore

      findings = findings_with_quarantine_component(report, 'quarantine_review_required')
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
      report.dead_methods(min_confidence: :low).select do |finding|
        finding.score_components.any? { |component| component.name == name }
      end
    end

    def filtered_findings(report, options)
      findings = report.dead_methods(min_confidence: options[:fail_on])
      return findings unless options[:diff_base]

      project = Project.new(root: File.expand_path(options[:root]), config: report_config(options))
      changed = project.changed_files(options[:diff_base])
      findings.select { |finding| changed.include?(finding.node.file) }
    end

    def report_config(options)
      Configuration.load(root: File.expand_path(options[:root]), path: options[:config])
    end

    def quarantine(options)
      report = analyze(options)
      quarantine = Guardrail::Quarantine.new(report: report, root: File.expand_path(options[:root]))
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
      raise Error, '--gold-standard is required for bench' unless options[:gold_standard]

      report = analyze(options)
      config = report_config(options)
      result = Bench::Evaluator.new(
        report: report,
        gold_standard_path: options[:gold_standard],
        min_confidence: options[:min_confidence],
        root: options[:root],
        config_path: options[:config],
        ablation: options[:ablation],
        precision_threshold: options[:precision_threshold] || config.bench_precision_threshold,
        recall_threshold: options[:recall_threshold] || config.bench_recall_threshold
      ).call
      puts JSON.pretty_generate(result)
      0
    end

    def record(options, argv)
      command = argv.dup
      raise Error, 'record requires a Ruby script or command after --' if command.empty?

      output = File.expand_path(options[:output] || 'tmp/necropsy_trace_point.yml', options[:root])
      FileUtils.mkdir_p(File.dirname(output))
      command = trace_command(options, command)
      run_id = SecureRandom.hex(16)
      status = system(trace_runtime_env(options, output, run_id), *command)
      puts "Wrote #{output}" if output_for_run?(output, run_id)
      return 0 if status

      $CHILD_STATUS&.exitstatus || 1
    end

    def coverage(options, argv)
      script_argv = argv.dup
      raise Error, 'coverage requires a Ruby script or command after --' if script_argv.empty?

      output = File.expand_path(options[:output] || 'tmp/necropsy_coverage.yml', options[:root])
      FileUtils.mkdir_p(File.dirname(output))

      return record_coverage_script(options, output, script_argv) if local_ruby_script?(options, script_argv)

      run_coverage_command(options, output, script_argv)
    end

    def record_coverage_script(options, output, script_argv)
      script, args = ruby_script_and_args(options, script_argv)
      previous_argv = ARGV.dup
      ARGV.replace(args)
      Analyzers::Dynamic::CoverageCollector.record(root: File.expand_path(options[:root]), output: output) do
        load File.expand_path(script, options[:root])
      end
      puts "Wrote #{output}"
      0
    ensure
      ARGV.replace(previous_argv) if previous_argv
    end

    def run_coverage_command(options, output, script_argv)
      run_id = SecureRandom.hex(16)
      status = system(coverage_runtime_env(options, output, run_id), *script_argv)
      puts "Wrote #{output}" if output_for_run?(output, run_id)
      return 0 if status

      $CHILD_STATUS&.exitstatus || 1
    end

    def local_ruby_script?(options, script_argv)
      script, = ruby_script_and_args(options, script_argv)
      script&.end_with?('.rb') && File.file?(File.expand_path(script, options[:root]))
    end

    def ruby_script_and_args(_options, script_argv)
      return [script_argv[1], script_argv.drop(2)] if script_argv.first == 'ruby'

      [script_argv.first, script_argv.drop(1)]
    end

    def coverage_runtime_env(options, output, run_id)
      rubyopt = [ENV.fetch('RUBYOPT', nil), '-rnecropsy/coverage_runtime'].compact.reject(&:empty?).join(' ')
      {
        'NECROPSY_COVERAGE_ROOT' => File.expand_path(options[:root]),
        'NECROPSY_COVERAGE_OUTPUT' => output,
        'NECROPSY_COVERAGE_MERGE' => '1',
        'NECROPSY_COVERAGE_RUN_ID' => run_id,
        'RUBYOPT' => rubyopt,
        'RUBYLIB' => rubylib
      }
    end

    def trace_runtime_env(options, output, run_id)
      rubyopt = [ENV.fetch('RUBYOPT', nil), '-rnecropsy/trace_point_runtime'].compact.reject(&:empty?).join(' ')
      {
        'NECROPSY_TRACE_ROOT' => File.expand_path(options[:root]),
        'NECROPSY_TRACE_OUTPUT' => output,
        'NECROPSY_TRACE_SAMPLE_RATE' => options[:sample_rate].to_s,
        'NECROPSY_TRACE_MERGE' => '1',
        'NECROPSY_TRACE_RUN_ID' => run_id,
        'RUBYOPT' => rubyopt,
        'RUBYLIB' => rubylib
      }
    end

    def trace_command(options, command)
      script = command.first
      path = File.expand_path(script, options[:root])
      return [RbConfig.ruby, path, *command.drop(1)] if script.end_with?('.rb') && File.file?(path)

      command
    end

    def rubylib
      paths = [File.expand_path('..', __dir__), ENV.fetch('RUBYLIB', nil)].compact.reject(&:empty?)
      paths.join(File::PATH_SEPARATOR)
    end

    def output_for_run?(output, run_id)
      payload = YAML.safe_load_file(output, aliases: false) || {}
      payload.dig('observation', 'run_id') == run_id
    rescue SystemCallError, Psych::Exception
      false
    end

    def confidence_level(value)
      level = value.to_sym
      return level if CONFIDENCE_LEVELS.key?(level)

      raise OptionParser::InvalidArgument, "unknown confidence level: #{value}"
    end
  end
end
