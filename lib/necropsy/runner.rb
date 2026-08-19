# frozen_string_literal: true

require 'json'
require_relative 'analyzer_execution'
require_relative 'analysis/pipeline'

module Necropsy
  class Runner
    ANALYZER_ERROR_MESSAGE_BYTES = AnalyzerExecution::ANALYZER_ERROR_MESSAGE_BYTES

    attr_reader :root, :config, :analyzers, :ignored_reference_paths, :clock

    def initialize(root:, config_path: nil, analyzers: nil, ignored_reference_paths: [], as_of: nil)
      @root = File.expand_path(root)
      @config = Configuration.load(root: @root, path: config_path)
      @analyzers = analyzers
      @ignored_reference_paths = ignored_reference_paths
      @clock = Clock.new(as_of: as_of)
    end

    def analyze(rta_pruning: config.rta_pruning, profile: false)
      Analysis::Pipeline.new(
        root: root,
        config: config,
        analyzers: analyzers,
        ignored_reference_paths: ignored_reference_paths,
        clock: clock,
        rta_pruning: rta_pruning,
        profile: profile
      ).call
    end
  end
end
