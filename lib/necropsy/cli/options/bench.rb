# frozen_string_literal: true

require_relative 'analysis'

module Necropsy
  class CLI
    module Options
      class Bench < Analysis
        private

        def define_options
          super
          options.merge!(
            gold_standard: nil,
            ablation: false,
            bench_check: false,
            precision_threshold: nil,
            recall_threshold: nil
          )
          parser.on('--gold-standard PATH', 'Gold standard YAML for bench') { |value| options[:gold_standard] = value }
          parser.on('--ablation', 'Run bench across analyzer combinations') { options[:ablation] = true }
          parser.on('--check', 'Fail bench when release criteria do not pass') { options[:bench_check] = true }
          parser.on('--precision-threshold N', Float, 'Bench release precision threshold') do |value|
            options[:precision_threshold] = value
          end
          parser.on('--recall-threshold N', Float, 'Bench release recall threshold') do |value|
            options[:recall_threshold] = value
          end
        end
      end
    end
  end
end
