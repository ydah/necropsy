# frozen_string_literal: true

module Necropsy
  module Bench
    module FindingFacts
      ACTIONABLE_CLASSIFICATIONS = %i[unreachable unused].freeze
      UNKNOWN_BLOCKER_KINDS = %i[
        analyzer_failure ambiguity_limit_exceeded dynamic_dispatch evidence_collision
        dynamic_ancestry incomplete_analysis incomplete_source parse_failure parse_incomplete
        partial_dispatch reference_scope_incomplete resolution_conflict resolution_invalid
        unknown_dispatch unparsed_external_reference unsupported_refinement variable_eval
      ].freeze
      RULE_ROOT_REASONS = %i[
        callback_registered rails_component rails_migration rails_route
        rails_view_helper rails_view_reference
      ].freeze
      ORDINARY_DEFINITION_KINDS = %i[def defs define_method].freeze

      module_function

      def actionable?(finding)
        return finding.actionable? if finding.respond_to?(:actionable?)

        ACTIONABLE_CLASSIFICATIONS.include?(finding.classification.to_sym)
      end

      def actionability(finding)
        return finding.actionability.to_s if finding.respond_to?(:actionability)

        actionable?(finding) ? 'review_candidate' : 'diagnostic'
      end

      def loc(finding)
        start_line = positive_integer(finding.node.line)
        end_line = positive_integer(finding.node.end_line) || start_line
        return 0 unless start_line

        [end_line - start_line + 1, 1].max
      end

      def unknown?(finding)
        finding.blockers.any? { |blocker| unknown_blocker?(blocker) }
      end

      def risk_flags(finding)
        node = finding.node
        flags = []
        flags << 'public_or_protected_visibility' if %i[public protected].include?(node.visibility.to_sym)
        flags << 'generated_method' unless ORDINARY_DEFINITION_KINDS.include?(node.defined_via.to_sym)
        flags << 'no_owner' if node.owner.to_s.empty?
        flags << 'test_definition' if node.test
        flags << 'analysis_incomplete' if finding.blockers.any?
        flags << 'duplicate_or_redefinition' if finding.blockers.any? do |blocker|
          blocker.kind.to_sym == :duplicate_definition
        end
        flags.uniq.sort
      end

      def rule_hits(finding)
        evidence_rules = finding.evidences.flat_map do |evidence|
          metadata = stringify_keys(evidence.metadata)
          values = [metadata['rule_id'], metadata['rule'], metadata['rules']]
          values.flatten.compact
        end
        blocker_rules = finding.blockers.filter_map do |blocker|
          metadata = stringify_keys(blocker.metadata)
          metadata['rule_id'] || metadata['rule']
        end
        (evidence_rules + blocker_rules).map(&:to_s).reject(&:empty?).uniq.sort
      end

      def category(finding)
        explicit = explicit_category(finding)
        return explicit if explicit

        blocker = finding.blockers.first
        return blocker.kind.to_s if blocker

        defined_via = finding.node.defined_via.to_sym
        return 'generated_method' unless ORDINARY_DEFINITION_KINDS.include?(defined_via)

        finding.classification.to_s
      end

      def report_rule_counts(report)
        finding_rules = report.reportable_findings.flat_map { |finding| rule_hits(finding) }
        root_rules = report.graph.entry_points.filter_map do |root|
          node = report.graph.nodes.exact(root.definition_id)
          next unless node && report_path?(report, node.file)

          root.reason.to_s if RULE_ROOT_REASONS.include?(root.reason.to_sym)
        end
        tally(finding_rules + root_rules)
      end

      def report_risk_counts(report)
        tally(report.reportable_findings.flat_map { |finding| risk_flags(finding) })
      end

      def tally(values)
        values.map(&:to_s).reject(&:empty?).tally.sort.to_h
      end

      def resolution_counts(report)
        visible_call_site_ids = report.graph.call_sites.filter_map do |site|
          site.call_site_id if report_path?(report, site.file)
        end.to_set
        records = report.graph.resolution_records.select do |record|
          visible_call_site_ids.include?(record.resolution.call_site_id)
        end
        counts = records.map { |record| record.resolution.status.to_s }.tally
        {
          'total' => records.length,
          'complete' => counts.fetch('complete', 0),
          'partial' => counts.fetch('partial', 0),
          'unknown' => counts.fetch('unknown', 0)
        }
      end

      def ratio(numerator, denominator)
        denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
      end

      def report_path?(report, path)
        !report.respond_to?(:report_path?) || report.report_path?(path)
      end
      private_class_method :report_path?

      def stringify_keys(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h.transform_keys(&:to_s)
      end
      private_class_method :stringify_keys

      def positive_integer(value)
        integer = Integer(value, exception: false)
        integer if integer&.positive?
      end
      private_class_method :positive_integer

      def unknown_blocker?(blocker)
        kind = blocker.kind.to_sym
        UNKNOWN_BLOCKER_KINDS.include?(kind) || kind.to_s.include?('unknown') || kind.to_s.include?('partial')
      end
      private_class_method :unknown_blocker?

      def explicit_category(finding)
        records = finding.evidences + finding.blockers
        records.each do |record|
          metadata = stringify_keys(record.metadata)
          value = metadata['benchmark_category'] || metadata['category']
          return value.to_s unless value.to_s.empty?
        end
        nil
      end
      private_class_method :explicit_category
    end
  end
end
