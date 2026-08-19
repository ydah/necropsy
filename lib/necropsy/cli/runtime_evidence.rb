# frozen_string_literal: true

require 'digest'
require 'English'
require 'fileutils'
require 'rbconfig'
require 'securerandom'
require 'yaml'

module Necropsy
  class CLI
    class RuntimeEvidence
      def initialize(run_id_generator:, environment:)
        @run_id_generator = run_id_generator
        @environment = environment
      end

      def record(options, argv)
        command = argv.dup
        raise Error, 'record requires a Ruby script or command after --' if command.empty?

        output = File.expand_path(options[:output] || 'tmp/necropsy_trace_point.yml', options[:root])
        FileUtils.mkdir_p(File.dirname(output))
        command = trace_command(options, command)
        run_id = artifact_run_id(options, output, 'trace_point')
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

      def artifact_run_id(options, output, kind)
        return @run_id_generator.call if @run_id_generator

        epoch = @environment.fetch(Clock::SOURCE_DATE_EPOCH, nil)
        reproducible = options[:as_of]&.iso8601 || epoch
        return SecureRandom.hex(16) unless reproducible

        Digest::SHA256.hexdigest([kind, File.expand_path(options[:root]), output, reproducible].join("\0"))[0, 32]
      end

      private

      def record_coverage_script(options, output, script_argv)
        script, args = ruby_script_and_args(script_argv)
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
        run_id = artifact_run_id(options, output, 'coverage')
        status = system(coverage_runtime_env(options, output, run_id), *script_argv)
        puts "Wrote #{output}" if output_for_run?(output, run_id)
        return 0 if status

        $CHILD_STATUS&.exitstatus || 1
      end

      def local_ruby_script?(options, script_argv)
        script, = ruby_script_and_args(script_argv)
        script&.end_with?('.rb') && File.file?(File.expand_path(script, options[:root]))
      end

      def ruby_script_and_args(script_argv)
        return [script_argv[1], script_argv.drop(2)] if script_argv.first == 'ruby'

        [script_argv.first, script_argv.drop(1)]
      end

      def coverage_runtime_env(options, output, run_id)
        rubyopt = [@environment.fetch('RUBYOPT', nil), '-rnecropsy/coverage_runtime'].compact.reject(&:empty?).join(' ')
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
        rubyopt = [@environment.fetch('RUBYOPT', nil), '-rnecropsy/trace_point_runtime'].compact.reject(&:empty?).join(' ')
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
        paths = [File.expand_path('../..', __dir__), @environment.fetch('RUBYLIB', nil)].compact.reject(&:empty?)
        paths.join(File::PATH_SEPARATOR)
      end

      def output_for_run?(output, run_id)
        payload = YAML.safe_load_file(output, aliases: false) || {}
        payload.dig('observation', 'run_id') == run_id
      rescue SystemCallError, Psych::Exception
        false
      end
    end
  end
end
