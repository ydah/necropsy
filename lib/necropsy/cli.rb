# frozen_string_literal: true

require 'necropsy'
require_relative 'cli/options'
require_relative 'cli/runtime_evidence'
require_relative 'cli/commands/resolver'

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
      command = select_command(argv)
      parsed_options = command_options.parse(argv, command: command)
      return print_help(parsed_options.parser) if parsed_options.options[:help]
      return print_version if parsed_options.options[:version]

      handler = resolver.resolve(command)
      return unknown_command(command, parsed_options.parser) unless handler

      handler.call(options: parsed_options.options, arguments: argv)
    rescue OptionParser::ParseError, Psych::Exception, Error, GraphSelfCheck::Failure,
           ArgumentError, TypeError, KeyError => e
      warn e.message
      2
    end

    private

    def select_command(argv)
      argv.first&.start_with?('-') ? 'analyze' : argv.shift || 'analyze'
    end

    def print_help(parser)
      puts parser
      0
    end

    def print_version
      puts Necropsy::VERSION
      0
    end

    def unknown_command(command, parser)
      warn "Unknown command: #{command}"
      warn parser
      2
    end

    def command_options
      @command_options ||= CommandOptions.new
    end

    def resolver
      @resolver ||= begin
        report_emitter = Commands::ReportEmitter.new
        Commands::Resolver.new(
          analysis: Commands::AnalysisExecutor.new(analyzer: Necropsy, self_checker: GraphSelfCheck),
          report_emitter: report_emitter,
          health: Commands::AnalysisHealth.new(
            failure_status: HEALTH_FAILURE_STATUS,
            report_emitter: report_emitter
          ),
          configuration: Configuration,
          clock: Clock,
          runtime_evidence: runtime_evidence
        )
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
