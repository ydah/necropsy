# frozen_string_literal: true

require 'date'
require 'optparse'

module Necropsy
  class CLI
    module Options
      class Base
        attr_reader :options, :parser

        def initialize
          @options = {
            root: '.',
            config: nil,
            help: false,
            version: false
          }
          @parser = OptionParser.new
          @parser.banner = 'Usage: necropsy COMMAND [options]'
          add_common_options
          define_options
        end

        def parse(argv)
          parser.parse!(argv)
          self
        end

        private

        def define_options; end

        def add_common_options
          parser.on('--root PATH', 'Project root') { |value| options[:root] = value }
          parser.on('--config PATH', 'Configuration file') { |value| options[:config] = value }
          parser.on('-h', '--help', 'Show help') { options[:help] = true }
          parser.on('-v', '--version', 'Show version') { options[:version] = true }
        end

        def add_format_option
          options[:format] = :human
          parser.on('--format FORMAT', Reporter::FORMATS.map(&:to_s), 'Output format') do |value|
            options[:format] = value.to_sym
          end
        end

        def add_as_of_option
          options[:as_of] = nil
          parser.on('--as-of DATE', 'Use a reproducible UTC date for time-dependent analysis') do |value|
            options[:as_of] = Date.iso8601(value)
          rescue Date::Error
            raise OptionParser::InvalidArgument, 'as-of must be an ISO 8601 date'
          end
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
end
