# frozen_string_literal: true

module Necropsy
  class GraphSelfCheck
    class Failure < StandardError; end

    def initialize(report)
      @report = report
    end

    def call
      [
        *resolution_issues,
        *derived_site_issues,
        *edge_issues,
        *finding_issues
      ].sort_by { |issue| BoundedCanonicalizer.dump(issue) }
    end

    def validate!
      issues = call
      return true if issues.empty?

      summary = issues.first(10).map do |issue|
        "#{issue.fetch('code')}: #{issue.fetch('subject')}"
      end.join('; ')
      raise Failure, "Graph self-check failed with #{issues.length} issue(s): #{summary}"
    end

    private

    attr_reader :report

    def resolution_issues
      graph.resolution_records.filter_map do |record|
        resolution = record.resolution
        if resolution.status == :complete && resolution.unknown_scope
          issue('complete_resolution_has_unknown_scope', resolution.call_site_id)
        elsif graph.call_sites.none? { |site| site.call_site_id == resolution.call_site_id }
          issue('resolution_call_site_missing', resolution.call_site_id)
        elsif resolution.target_definition_ids.any? { |definition_id| !graph.nodes.exact(definition_id) }
          issue('resolution_target_missing', resolution.call_site_id)
        end
      end
    end

    def derived_site_issues
      graph.call_sites.filter_map do |site|
        next unless site.metadata['derived_from_call_site_id']
        next unless graph.resolution_records(site.call_site_id).empty?

        issue('derived_call_site_has_no_resolution', site.call_site_id)
      end
    end

    def edge_issues
      graph.edges.filter_map do |edge|
        issue('edge_has_no_evidence', "#{edge.caller_id}->#{edge.callee_id}") if edge.evidences.empty?
      end
    end

    def finding_issues
      report.actionable_candidates.filter_map do |finding|
        blockers = graph.matching_blockers(finding.node)
        next if finding.blockers.empty? && blockers.empty?

        issue('actionable_finding_has_matching_blocker', finding.node.graph_id)
      end
    end

    def graph
      report.graph
    end

    def issue(code, subject)
      { 'code' => code, 'subject' => subject.to_s }
    end
  end
end
