# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative '../../removal_workflow'

module Necropsy
  class CLI
    module Commands
      class Removal
        def initialize(removal:, command:)
          @workflow_class = removal
          @command = command
        end

        def call(options:, arguments:)
          raise Error, "#{@command} requires --report and --candidate" unless options[:report] && options[:candidate]

          workflow = @workflow_class.new(
            report_path: options[:report],
            candidate: options[:candidate],
            root: File.expand_path(options[:root]),
            timeout_seconds: options[:verify_timeout] || @workflow_class::DEFAULT_TIMEOUT_SECONDS
          )
          case @command
          when 'plan'
            result = workflow.plan
            write_or_print(result, options[:output], root: options[:root])
            0
          when 'patch'
            result = workflow.patch_preview
            write_or_print(result, options[:output], root: options[:root], raw: true)
            0
          when 'verify'
            raise Error, 'verify requires a command after --' if arguments.empty?

            result = workflow.verify(arguments)
            puts JSON.pretty_generate(result)
            result.fetch('passed') ? 0 : 1
          end
        end

        private

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
      end
    end
  end
end
