# frozen_string_literal: true

require 'json'
require_relative 'finding_facts'

module Necropsy
  module Bench
    class ReportNormalizer
      VERSION = 1

      def initialize(report:, corpus:)
        @report = report
        @corpus = corpus
      end

      def call
        {
          'schema_version' => VERSION,
          'corpus' => corpus,
          'metrics' => metrics,
          'states' => state_counts,
          'quality' => quality,
          'findings' => normalized_findings
        }
      end

      def dump
        "#{JSON.pretty_generate(call)}\n"
      end

      private

      attr_reader :report, :corpus

      def metrics
        {
          'analysis_graph' => {
            'scope' => 'analysis',
            'nodes' => report.graph.nodes.length,
            'definitions' => report.graph.method_nodes.length,
            'call_sites' => report.graph.call_sites.length,
            'edges' => report.graph.edges.length
          },
          'findings' => reportable_findings.length,
          'actionable_candidates' => actionable_findings.length,
          'candidate_loc' => actionable_findings.sum { |finding| FindingFacts.loc(finding) },
          'diagnostic_findings' => diagnostic_findings.length
        }
      end

      def state_counts
        reportable_findings.group_by(&:classification).transform_values(&:length).transform_keys(&:to_s).sort.to_h
      end

      def normalized_findings
        reportable_findings.sort_by do |finding|
          [finding.node.id, finding.node.file, finding.node.line, finding.node.definition_id]
        end.map do |finding|
          {
            'id' => finding.node.id,
            'definition_id' => finding.node.definition_id,
            'path' => finding.node.file,
            'line' => finding.node.line,
            'end_line' => finding.node.end_line,
            'loc' => FindingFacts.loc(finding),
            'state' => finding.classification.to_s,
            'confidence' => finding.confidence.to_s,
            'candidate' => FindingFacts.actionable?(finding),
            'diagnostic' => !FindingFacts.actionable?(finding),
            'actionability' => FindingFacts.actionability(finding),
            'reachability_state' => finding.reachability_state.to_s,
            'analysis_completeness' => finding.analysis_completeness.to_s,
            'priority_score' => finding.score,
            'category' => FindingFacts.category(finding),
            'unknown' => FindingFacts.unknown?(finding),
            'rule_hits' => FindingFacts.rule_hits(finding),
            'risk_flags' => FindingFacts.risk_flags(finding),
            'blocker_kinds' => finding.blockers.map { |blocker| blocker.kind.to_s }.uniq.sort,
            'reasons' => finding.reasons.map(&:to_s).sort
          }
        end
      end

      def quality
        resolutions = FindingFacts.resolution_counts(report)
        grouped = reportable_findings.group_by { |finding| FindingFacts.category(finding) }
        {
          'scope' => 'report',
          'candidate_count' => actionable_findings.length,
          'candidate_loc' => actionable_findings.sum { |finding| FindingFacts.loc(finding) },
          'diagnostic_count' => diagnostic_findings.length,
          'blocked_count' => blocked_findings.length,
          'blocked_rate' => FindingFacts.ratio(blocked_findings.length, reportable_findings.length),
          'unknown_finding_count' => unknown_findings.length,
          'unknown_finding_rate' => FindingFacts.ratio(unknown_findings.length, reportable_findings.length),
          'resolution_counts' => resolutions,
          'unknown_resolution_rate' => FindingFacts.ratio(resolutions.fetch('unknown'), resolutions.fetch('total')),
          'rule_counts' => FindingFacts.report_rule_counts(report),
          'risk_counts' => FindingFacts.report_risk_counts(report),
          'by_category' => grouped.sort.to_h do |category, findings|
            [category, category_quality(findings)]
          end
        }
      end

      def category_quality(findings)
        candidates = findings.select { |finding| FindingFacts.actionable?(finding) }
        blocked = findings.select { |finding| finding.classification == :blocked }
        unknown = findings.select { |finding| FindingFacts.unknown?(finding) }
        {
          'findings' => findings.length,
          'candidate_count' => candidates.length,
          'candidate_loc' => candidates.sum { |finding| FindingFacts.loc(finding) },
          'blocked_count' => blocked.length,
          'blocked_rate' => FindingFacts.ratio(blocked.length, findings.length),
          'unknown_count' => unknown.length,
          'unknown_rate' => FindingFacts.ratio(unknown.length, findings.length),
          'rule_counts' => FindingFacts.tally(findings.flat_map { |finding| FindingFacts.rule_hits(finding) }),
          'risk_counts' => FindingFacts.tally(findings.flat_map { |finding| FindingFacts.risk_flags(finding) })
        }
      end

      def actionable_findings
        @actionable_findings ||= reportable_findings.select { |finding| FindingFacts.actionable?(finding) }
      end

      def diagnostic_findings
        @diagnostic_findings ||= reportable_findings.reject { |finding| FindingFacts.actionable?(finding) }
      end

      def blocked_findings
        @blocked_findings ||= reportable_findings.select { |finding| finding.classification == :blocked }
      end

      def unknown_findings
        @unknown_findings ||= reportable_findings.select { |finding| FindingFacts.unknown?(finding) }
      end

      def reportable_findings
        @reportable_findings ||= report.reportable_findings
      end
    end
  end
end
