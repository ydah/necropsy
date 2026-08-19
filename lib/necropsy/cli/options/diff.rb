# frozen_string_literal: true

require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Diff < Base
        private

        def define_options
          add_format_option
          options.merge!(base_report: nil, head_report: nil)
          parser.on('--base PATH_OR_REVISION', 'Base report path or Git revision for causal diff') do |value|
            options[:base_report] = value
          end
          parser.on('--head PATH_OR_REVISION', 'Head report or Git revision for causal diff') do |value|
            options[:head_report] = value
          end
        end
      end
    end
  end
end
