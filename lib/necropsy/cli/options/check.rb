# frozen_string_literal: true

require_relative 'analysis'

module Necropsy
  class CLI
    module Options
      class Check < Analysis
        private

        def define_options
          super
          options.merge!(baseline: nil, fail_on: nil, diff_base: nil, ratchet: false)
          parser.on('--baseline PATH', 'Baseline path') { |value| options[:baseline] = value }
          parser.on('--fail-on LEVEL', 'CI failure threshold') { |value| options[:fail_on] = ci_threshold(value) }
          parser.on('--diff-base REV', 'Restrict reported findings to files changed since REV') do |value|
            options[:diff_base] = value
          end
          parser.on('--ratchet', 'Fail if finding count grows beyond baseline count') { options[:ratchet] = true }
        end
      end
    end
  end
end
