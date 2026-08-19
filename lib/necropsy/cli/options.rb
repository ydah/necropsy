# frozen_string_literal: true

require 'date'
require 'optparse'

module Necropsy
  class CLI
    class CommandOptions
      ParseResult = Struct.new(:options, :parser, keyword_init: true)

      def initialize(configuration: Configuration)
        @configuration = configuration
      end

      def parse(argv, command:)
        options = default_options
        parser = build_parser(options)
        parser.parse!(argv)
        apply_config_defaults(options) if load_config_defaults?(options, command)
        ParseResult.new(options: options, parser: parser)
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
          verify_timeout: nil
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
          parser.on('--head PATH_OR_REVISION', 'Head report or Git revision for causal diff') do |value|
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

      def load_config_defaults?(options, command)
        command != 'semantics' && !options[:help] && !options[:version]
      end

      def apply_config_defaults(options)
        config = @configuration.load(root: File.expand_path(options[:root]), path: options[:config])
        options[:baseline] ||= config.baseline_path
        options[:fail_on] ||= config.fail_on
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
    end
  end
end
