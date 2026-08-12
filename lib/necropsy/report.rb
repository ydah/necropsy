# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'

module Necropsy
  class Report
    SCHEMA_VERSION = 2
    SCHEMA_PATH = File.expand_path("../../schema/necropsy-report-v#{SCHEMA_VERSION}.schema.json", __dir__).freeze
    ACTIONABLE_CLASSIFICATIONS = %i[unreachable unused].freeze
    FINGERPRINT_COMPATIBILITY = {
      'fingerprint' => 'legacy logical symbol fingerprint retained for compatibility',
      'physical_fingerprint' => 'physical definition fingerprint for baselines and definition-level matching'
    }.freeze

    attr_reader :root, :graph, :findings, :reachability, :project, :source_snapshot, :performance_profile,
                :analysis_health

    def self.schema_path
      SCHEMA_PATH
    end

    def initialize(root:, graph:, findings:, reachability: nil, report_include_paths: [], report_exclude_paths: [],
                   project: nil, source_snapshot: nil, performance_profile: nil, analysis_health: nil)
      @root = root
      @graph = graph
      @findings = findings.sort_by do |finding|
        [finding.node.file, finding.node.line, finding.node.id, finding.node.definition_id]
      end
      @reachability = reachability
      @project = project
      @source_snapshot = source_snapshot
      @performance_profile = performance_profile
      @analysis_health = analysis_health || AnalysisHealth.complete
      @report_include_paths = report_include_paths
      @report_exclude_paths = report_exclude_paths
    end

    def dead_methods(min_confidence: :low)
      reported_findings.select { |finding| finding.at_least?(min_confidence) }
    end

    # Unlike the legacy dead_methods API, this excludes findings that exist to
    # explain uncertainty or test-only reachability. Benchmarks and precision
    # gates must measure only definitions that a user can actually review as a
    # removal candidate.
    def actionable_candidates(min_confidence: :low)
      reported_findings.select do |finding|
        ACTIONABLE_CLASSIFICATIONS.include?(finding.classification) && finding.at_least?(min_confidence)
      end
    end

    def diagnostic_findings
      reported_findings.reject { |finding| ACTIONABLE_CLASSIFICATIONS.include?(finding.classification) }
    end

    def reportable_findings
      reported_findings.dup
    end

    def finding_for_definition(definition_id)
      @findings_by_definition ||= findings.to_h { |finding| [finding.node.graph_id, finding] }.freeze
      @findings_by_definition[definition_id.to_s]
    end

    def report_path?(path)
      included_in_report?(path) && !excluded_from_report?(path)
    end

    def blocked_methods
      reported_findings.select { |finding| finding.classification == :blocked }
    end

    def to_h(include_graph: false)
      payload = {
        'schema_version' => SCHEMA_VERSION,
        'artifact_provenance' => artifact_provenance,
        'compatibility' => { 'finding_fingerprints' => FINGERPRINT_COMPATIBILITY },
        'root' => root,
        'analysis_health' => analysis_health.to_h,
        'summary' => summary,
        'findings' => reported_findings.map(&:to_h)
      }
      payload['diagnostics'] = diagnostics unless diagnostics.empty?
      payload['source_snapshot'] = source_snapshot if source_snapshot
      payload['graph'] = graph.to_h if include_graph
      payload
    end

    def to_json(state = nil, include_graph: false)
      payload = to_h(include_graph: include_graph)
      return JSON.pretty_generate(payload) unless state

      payload.to_json(state)
    end

    def to_yaml(include_graph: false)
      to_h(include_graph: include_graph).to_yaml
    end

    def summary
      grouped = reported_findings.group_by(&:classification)
      actionable = reported_findings.count { |finding| ACTIONABLE_CLASSIFICATIONS.include?(finding.classification) }
      blocked = grouped.fetch(:blocked, []).length
      {
        'nodes' => graph.nodes.length,
        'edges' => graph.edges.length,
        'entry_points' => graph.entry_points.length,
        'incomplete_files' => graph.incomplete_files.length,
        'findings' => reported_findings.length,
        'actionable' => actionable,
        'diagnostic' => reported_findings.length - actionable - blocked,
        'health_failures' => analysis_health.reasons.length,
        'unreachable' => grouped.fetch(:unreachable, []).length,
        'unused' => grouped.fetch(:unused, []).length,
        'blocked' => blocked,
        'test_only_reachable' => grouped.fetch(:test_only_reachable, []).length
      }
    end

    def diagnostics
      result = {}
      dynamic = graph.dynamic_evidence_diagnostic
      result['dynamic_evidence'] = dynamic if dynamic
      definition_resolution = graph.observation['definition_resolution']
      result['definition_resolution'] = definition_resolution if definition_resolution
      reference_barrier = graph.observation['non_ruby_reference_barrier']
      result['non_ruby_reference_barrier'] = reference_barrier if reference_barrier
      result['source_incompleteness'] = graph.source_incompleteness if graph.incomplete_files.any?
      result['analysis_scope'] = graph.scope_diagnostics unless graph.scope_diagnostics.empty?
      unrooted = graph.observation['unrooted_load_units']
      result['unrooted_load_units'] = unrooted if unrooted && unrooted['count'].positive?
      result['performance'] = performance_profile if performance_profile
      result
    end

    private

    attr_reader :report_include_paths, :report_exclude_paths

    def artifact_provenance
      {
        'producer' => { 'name' => 'necropsy', 'version' => Necropsy::VERSION },
        'runtime' => {
          'ruby_engine' => RUBY_ENGINE,
          'ruby_version' => RUBY_VERSION,
          'prism_version' => Prism::VERSION
        },
        'identity_schemas' => {
          'definition' => DefinitionIdentity::VERSION,
          'call_site' => CallSiteIdentity::VERSION
        },
        'inputs' => {
          'configuration_sha256' => configuration_digest
        }
      }
    end

    def configuration_digest
      return 'unavailable' unless project

      Digest::SHA256.hexdigest(BoundedCanonicalizer.dump(project.config.scan_cache_key))
    rescue BoundedCanonicalizer::Error, SystemStackError
      'unavailable'
    end

    def reported_findings
      @reported_findings ||= findings.select do |finding|
        report_path?(finding.node.file)
      end
    end

    def included_in_report?(path)
      report_include_paths.empty? || report_include_paths.any? { |pattern| path_matches?(pattern, path) }
    end

    def excluded_from_report?(path)
      report_exclude_paths.any? { |pattern| path_matches?(pattern, path) }
    end

    def path_matches?(pattern, path)
      File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
        File.fnmatch?(File.join(pattern, '**', '*'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
  end
end
