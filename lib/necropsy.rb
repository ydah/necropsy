# frozen_string_literal: true

# Set is built in on supported Rubies, but requiring it keeps direct file loading portable.
require 'set' # rubocop:disable Lint/RedundantRequireStatement

require_relative 'necropsy/version'
require_relative 'necropsy/models'
require_relative 'necropsy/configuration'
require_relative 'necropsy/ast_scanner'
require_relative 'necropsy/cache/scan_cache'
require_relative 'necropsy/project'
require_relative 'necropsy/graph/call_graph'
require_relative 'necropsy/analyzer'
require_relative 'necropsy/analyzers/static/name_resolution'
require_relative 'necropsy/analyzers/static/cha'
require_relative 'necropsy/analyzers/static/rta'
require_relative 'necropsy/analyzers/dynamic/coverage_importer'
require_relative 'necropsy/analyzers/dynamic/coverage_collector'
require_relative 'necropsy/analyzers/dynamic/coverband_importer'
require_relative 'necropsy/analyzers/dynamic/trace_point_importer'
require_relative 'necropsy/analyzers/dynamic/trace_point_collector'
require_relative 'necropsy/entry_points/plain'
require_relative 'necropsy/entry_points/rails'
require_relative 'necropsy/entry_points/test'
require_relative 'necropsy/reachability/engine'
require_relative 'necropsy/confidence/scorer'
require_relative 'necropsy/report'
require_relative 'necropsy/reporter'
require_relative 'necropsy/diagnostics'
require_relative 'necropsy/guardrail/baseline'
require_relative 'necropsy/guardrail/diff'
require_relative 'necropsy/guardrail/quarantine'
require_relative 'necropsy/bench/evaluator'
require_relative 'necropsy/runner'

module Necropsy
  class Error < StandardError; end

  def self.analyze(root: '.', config_path: nil, analyzers: nil)
    Runner.new(root: root, config_path: config_path, analyzers: analyzers).analyze
  end

  def self.default_analyzers
    [
      Analyzers::Static::NameResolution.new,
      Analyzers::Static::CHA.new,
      Analyzers::Static::RTA.new
    ]
  end
end
