# frozen_string_literal: true

require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Removal < Base
        private

        def define_options
          add_format_option
          options.merge!(report: nil, candidate: nil, output: nil, verify_timeout: nil)
          parser.on('--report PATH', 'Static report or proof report path') { |value| options[:report] = value }
          parser.on('--candidate ID', 'Physical definition ID or unique symbol ID') do |value|
            options[:candidate] = value
          end
          parser.on('--output PATH', 'Output path for record') { |value| options[:output] = value }
          parser.on('--verify-timeout SECONDS', Float, 'Maximum removal verification time') do |value|
            raise OptionParser::InvalidArgument, 'verify-timeout must be positive and finite' unless value.positive? && value.finite?

            options[:verify_timeout] = value
          end
        end
      end
    end
  end
end
