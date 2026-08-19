# frozen_string_literal: true

require 'json'
require_relative '../../bench/evaluator'
require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Bench
        def initialize(analysis:, health:, configuration:)
          @analysis = analysis
          @health = health
          @configuration = configuration
        end

        def call(options:, arguments:)
          raise Error, "Unexpected bench arguments: #{arguments.join(' ')}" unless arguments.empty?
          raise Error, '--gold-standard is required for bench' unless options[:gold_standard]

          gold_standard_path = File.expand_path(options[:gold_standard])
          report = @analysis.call(options: options, ignored_reference_paths: [gold_standard_path])
          return @health.failure(report: report, options: options) unless
            @health.acceptable?(report: report, options: options, strict: true)

          config = @configuration.load(root: File.expand_path(options[:root]), path: options[:config])
          result = ::Necropsy::Bench::Evaluator.new(
            report: report,
            gold_standard_path: gold_standard_path,
            min_confidence: options[:min_confidence],
            root: options[:root],
            config_path: options[:config],
            ablation: options[:ablation],
            precision_threshold: options[:precision_threshold] || config.bench_precision_threshold,
            recall_threshold: options[:recall_threshold] || config.bench_recall_threshold
          ).call
          puts JSON.pretty_generate(result)
          options[:bench_check] && !result.dig('release_criteria', 'passed') ? 1 : 0
        end
      end
    end
  end
end
