# frozen_string_literal: true

# Set is built in on supported Rubies, but requiring it keeps direct file loading portable.
require 'set' # rubocop:disable Lint/RedundantRequireStatement

require_relative 'necropsy/version'
require_relative 'necropsy/clock'
require_relative 'necropsy/bounded_canonicalizer'
require_relative 'necropsy/call_site_identity'
require_relative 'necropsy/models'
require_relative 'necropsy/definition_identity'
require_relative 'necropsy/configuration'
require_relative 'necropsy/flow_interpreter'
require_relative 'necropsy/convention_rules'
require_relative 'necropsy/runtime_feedback'
require_relative 'necropsy/artifact_loader'
require_relative 'necropsy/feedback_workflow'
require_relative 'necropsy/performance_profiler'
require_relative 'necropsy/embedded_ruby'
require_relative 'necropsy/ast_scanner'
require_relative 'necropsy/cache/scan_cache'
require_relative 'necropsy/project'
require_relative 'necropsy/graph/definition_index'
require_relative 'necropsy/graph/dynamic_evidence_tracking'
require_relative 'necropsy/graph/evidence_store'
require_relative 'necropsy/graph/blocker_matching'
require_relative 'necropsy/graph/resolution_store'
require_relative 'necropsy/graph/call_graph'
require_relative 'necropsy/graph_self_check'
require_relative 'necropsy/semantics_matrix'
require_relative 'necropsy/analyzer'
require_relative 'necropsy/analyzers/legacy_result_adapter'
require_relative 'necropsy/analyzers/static/name_resolution'
require_relative 'necropsy/analyzers/static/cha'
require_relative 'necropsy/analyzers/static/rta'
require_relative 'necropsy/analyzers/dynamic/observation_policy'
require_relative 'necropsy/analyzers/dynamic/coverage_importer'
require_relative 'necropsy/analyzers/dynamic/coverage_collector'
require_relative 'necropsy/analyzers/dynamic/coverband_importer'
require_relative 'necropsy/analyzers/dynamic/trace_point_importer'
require_relative 'necropsy/analyzers/dynamic/trace_point_collector'
require_relative 'necropsy/entry_points/plain'
require_relative 'necropsy/entry_points/rails'
require_relative 'necropsy/entry_points/test'
require_relative 'necropsy/load_graph'
require_relative 'necropsy/world_policy'
require_relative 'necropsy/reachability/engine'
require_relative 'necropsy/confidence/scorer'
require_relative 'necropsy/report'
require_relative 'necropsy/reporter'
require_relative 'necropsy/doctor'
require_relative 'necropsy/why_not_explanation'
require_relative 'necropsy/why_not_renderer'
require_relative 'necropsy/diagnostics'
require_relative 'necropsy/reference_barrier'
require_relative 'necropsy/guardrail/baseline'
require_relative 'necropsy/guardrail/diff'
require_relative 'necropsy/guardrail/revision_diff'
require_relative 'necropsy/removal_workflow'
require_relative 'necropsy/guardrail/quarantine'
require_relative 'necropsy/bench/finding_facts'
require_relative 'necropsy/bench/evaluator'
require_relative 'necropsy/bench/claim_gate'
require_relative 'necropsy/bench/review_queue'
require_relative 'necropsy/runner'

module Necropsy
  class Error < StandardError; end

  def self.analyze(root: '.', config_path: nil, analyzers: nil, ignored_reference_paths: [], profile: false, as_of: nil)
    Runner.new(
      root: root,
      config_path: config_path,
      analyzers: analyzers,
      ignored_reference_paths: ignored_reference_paths,
      as_of: as_of
    ).analyze(profile: profile)
  end
end
