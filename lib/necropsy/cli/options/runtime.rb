# frozen_string_literal: true

require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Runtime < Base
        private

        def define_options
          add_as_of_option
          options.merge!(output: nil, sample_rate: 1.0)
          parser.on('--output PATH', 'Output path for record') { |value| options[:output] = value }
          parser.on('--sample-rate RATE', Float, 'TracePoint sample rate for record') do |value|
            raise OptionParser::InvalidArgument, 'sample rate must be between 0.0 and 1.0' unless value.between?(0.0, 1.0)

            options[:sample_rate] = value
          end
        end
      end

      class Record < Runtime; end
      class Coverage < Runtime; end
    end
  end
end
