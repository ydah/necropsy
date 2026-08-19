# frozen_string_literal: true

require 'json'
require_relative '../../guardrail/diff'

module Necropsy
  class CLI
    module Commands
      class Diff
        def initialize(diff:)
          @diff = diff
        end

        def call(options:, arguments:)
          raise Error, "Unexpected diff arguments: #{arguments.join(' ')}" unless arguments.empty?
          raise Error, 'diff requires --base' unless options[:base_report]

          base_path = File.expand_path(options[:base_report], options[:root])
          head_path = options[:head_report] && File.expand_path(options[:head_report], options[:root])
          result = if head_path && File.file?(base_path) && File.file?(head_path)
                     @diff.compare_reports(base_path: base_path, head_path: head_path)
                   elsif !options[:head_report] && !File.file?(base_path)
                     @diff.compare_revisions(
                       root: options[:root], base_revision: options[:base_report], config_path: options[:config]
                     )
                   elsif options[:head_report] && !File.file?(base_path) && !File.file?(head_path)
                     @diff.compare_revisions(
                       root: options[:root], base_revision: options[:base_report],
                       head_revision: options[:head_report], config_path: options[:config]
                     )
                   else
                     raise Error, 'diff expects two report paths or one/two Git revisions'
                   end
          puts JSON.pretty_generate(result)
          0
        end
      end
    end
  end
end
