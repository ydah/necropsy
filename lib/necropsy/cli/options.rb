# frozen_string_literal: true

require_relative 'options/base'
require_relative 'options/analysis'
require_relative 'options/analyze'
require_relative 'options/baseline'
require_relative 'options/bench'
require_relative 'options/check'
require_relative 'options/diagnostics'
require_relative 'options/diff'
require_relative 'options/doctor'
require_relative 'options/feedback'
require_relative 'options/quarantine'
require_relative 'options/removal'
require_relative 'options/runtime'
require_relative 'options/semantics'

module Necropsy
  class CLI
    class CommandOptions
      ParseResult = Struct.new(:options, :parser, keyword_init: true)

      PARSERS = {
        'analyze' => Options::Analyze,
        'baseline' => Options::Baseline,
        'check' => Options::Check,
        'quarantine' => Options::Quarantine,
        'bench' => Options::Bench,
        'doctor' => Options::Doctor,
        'feedback' => Options::Feedback,
        'diff' => Options::Diff,
        'plan' => Options::Removal,
        'patch' => Options::Removal,
        'verify' => Options::Removal,
        'why' => Options::Diagnostics,
        'why-not' => Options::Diagnostics,
        'explain' => Options::Diagnostics,
        'semantics' => Options::Semantics,
        'record' => Options::Record,
        'coverage' => Options::Coverage
      }.freeze

      def initialize(configuration: Configuration)
        @configuration = configuration
      end

      def parse(argv, command:)
        command_parser = parser_for(command).new
        command_parser.parse(argv)
        apply_config_defaults(command_parser.options) if load_config_defaults?(command_parser.options, command)

        ParseResult.new(options: command_parser.options, parser: command_parser.parser)
      end

      private

      def parser_for(command)
        PARSERS.fetch(command, Options::Analyze)
      end

      def load_config_defaults?(options, command)
        command != 'semantics' && !options[:help] && !options[:version]
      end

      def apply_config_defaults(options)
        config = @configuration.load(root: File.expand_path(options[:root]), path: options[:config])
        options[:baseline] ||= config.baseline_path if options.key?(:baseline)
        options[:fail_on] ||= config.fail_on if options.key?(:fail_on)
      end
    end
  end
end
