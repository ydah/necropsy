# frozen_string_literal: true

require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Feedback < Base
        private

        def define_options
          add_format_option
          options.merge!(
            report: nil,
            observed: nil,
            output: nil,
            max_fixtures: RuntimeFeedback::DEFAULT_FIXTURE_LIMIT,
            fail_on_missing_static_target: false
          )
          parser.on('--report PATH', 'Static report or proof report path') { |value| options[:report] = value }
          parser.on('--observed PATH', 'Runtime observed-target artifact path') { |value| options[:observed] = value }
          parser.on('--output PATH', 'Output path for record') { |value| options[:output] = value }
          parser.on('--max-fixtures N', Integer, 'Maximum exported runtime feedback fixtures') do |value|
            raise OptionParser::InvalidArgument, 'max-fixtures must be non-negative' if value.negative?

            options[:max_fixtures] = value
          end
          parser.on('--fail-on-missing-static-target', 'Fail feedback verification on a missing static target') do
            options[:fail_on_missing_static_target] = true
          end
        end
      end
    end
  end
end
