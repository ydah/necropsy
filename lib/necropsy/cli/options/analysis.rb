# frozen_string_literal: true

require 'date'
require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Analysis < Base
        private

        def define_options
          add_format_option
          add_as_of_option
          options.merge!(
            include_graph: false,
            self_check: false,
            min_confidence: Reporter::DEFAULT_MIN_CONFIDENCE,
            strict_health: false,
            allow_degraded: []
          )
          add_analysis_options
        end

        def add_analysis_options
          parser.on('--include-graph', 'Include nodes and edges in JSON/YAML output') do
            options[:include_graph] = true
          end
          parser.on('--self-check', 'Validate graph invariants after analysis') { options[:self_check] = true }
          parser.on('--min-confidence LEVEL', 'low, medium, high, or certain') do |value|
            options[:min_confidence] = confidence_level(value)
          end
          parser.on('--strict-health', 'Return status 3 unless analysis health is complete') do
            options[:strict_health] = true
          end
          parser.on('--allow-degraded=REASONS', 'Comma-separated degraded reason codes to allow explicitly') do |value|
            reasons = value.split(',').map(&:strip).reject(&:empty?)
            raise OptionParser::InvalidArgument, 'allow-degraded requires at least one reason code' if reasons.empty?
            unless reasons.all? { |reason| reason.match?(/\A[a-z][a-z0-9_]*\z/) }
              raise OptionParser::InvalidArgument, 'allow-degraded reason codes must use lowercase letters, numbers, and _'
            end

            options[:allow_degraded] |= reasons
          end
        end
      end
    end
  end
end
