# frozen_string_literal: true

require 'open3'
require 'json'
require 'yaml'

module Necropsy
  module Guardrail
    class Diff
      def self.changed_files(root:, diff_base:)
        stdout, stderr, status = Open3.capture3('git', '-C', root, 'diff', '--name-only', "#{diff_base}...HEAD")
        unless status.success?
          detail = stderr.strip.empty? ? 'unknown git error' : stderr.strip
          raise Error, "Could not determine changed files from #{diff_base}: #{detail}"
        end

        stdout.lines.map(&:strip).reject(&:empty?).to_set
      end

      def self.compare_reports(base_path:, head_path:)
        new(base: load_report(base_path), head: load_report(head_path)).compare
      end

      def self.load_report(path)
        contents = File.read(File.expand_path(path))
        JSON.parse(contents)
      rescue JSON::ParserError
        YAML.safe_load(contents, aliases: false) || {}
      rescue SystemCallError, Psych::Exception => e
        raise Error, "Could not read diff report #{path}: #{e.message}"
      end

      private_class_method :load_report

      def initialize(base:, head:)
        @base = base
        @head = head
      end

      def compare
        base_findings = findings_by_definition(@base)
        head_findings = findings_by_definition(@head)
        base_graph = @base['graph'] || {}
        head_graph = @head['graph'] || {}
        {
          'schema_version' => 1,
          'base' => report_identity(@base),
          'head' => report_identity(@head),
          'newly_unreachable' => newly_unreachable(base_findings, head_findings, head_graph),
          'newly_reachable' => newly_reachable(base_findings, head_findings, head_graph),
          'newly_blocked' => state_changes(base_findings, head_findings, 'blocked'),
          'blocker_removed' => blocker_removed(base_findings, head_findings),
          'entry_point_removed' => difference_ids(base_graph['entry_points'], head_graph['entry_points']),
          'load_unit_unrooted' => load_unit_diff(@base, @head),
          'dispatch_became_partial' => dispatch_changes(base_graph, head_graph),
          'analysis_health_changed' => health_change(@base, @head),
          'public_surface_changed' => public_surface_changes(base_graph, head_graph),
          'runtime_evidence_invalidated' => runtime_evidence_invalidated(@base, @head)
        }
      end

      private

      def findings_by_definition(report)
        Array(report['findings']).each_with_object({}) do |finding, result|
          node = finding['node'] || {}
          key = node['definition_id'] || finding['physical_fingerprint'] || finding['fingerprint']
          result[key] = finding if key
        end
      end

      def newly_unreachable(base, head, graph)
        head.filter_map do |definition_id, finding|
          next unless candidate?(finding)
          next if candidate?(base[definition_id])

          finding_with_witness(finding, graph, definition_id)
        end.sort_by { |finding| sort_key(finding) }
      end

      def newly_reachable(base, head, graph)
        base.filter_map do |definition_id, finding|
          next unless candidate?(finding)
          next if head.key?(definition_id)
          next unless graph_node(graph, definition_id)

          finding_identity(finding).merge('state' => 'newly_reachable')
        end.sort_by { |finding| sort_key(finding) }
      end

      def state_changes(base, head, state)
        head.filter_map do |definition_id, finding|
          next unless finding['classification'].to_s == state

          previous = base[definition_id]
          next if previous && previous['classification'].to_s == state

          finding_identity(finding).merge('state' => "newly_#{state}")
        end.sort_by { |finding| sort_key(finding) }
      end

      def blocker_removed(base, head)
        base.filter_map do |definition_id, finding|
          next unless finding['classification'].to_s == 'blocked'

          current = head[definition_id]
          next unless current.nil? || current['classification'].to_s != 'blocked'

          finding_identity(finding).merge('state' => 'blocker_removed')
        end.sort_by { |finding| sort_key(finding) }
      end

      def finding_with_witness(finding, graph, definition_id)
        edges = Array(graph['edges'])
        incoming = edges.select { |edge| edge['callee_id'].to_s == definition_id.to_s }
        finding_identity(finding).merge(
          'state' => 'newly_unreachable',
          'proof_obligations' => %w[source load dispatch framework external_contract dynamic_evidence],
          'incoming_edges' => incoming.sort_by { |edge| [edge['caller_id'].to_s, edge['callee_id'].to_s] },
          'last_incoming_edge' => incoming.one? ? incoming.first : nil
        ).compact
      end

      def finding_identity(finding)
        node = finding['node'] || {}
        {
          'definition_id' => node['definition_id'] || finding['physical_fingerprint'],
          'symbol_id' => node['symbol_id'] || node['id'],
          'file' => node['file'],
          'line' => node['line'],
          'classification' => finding['classification'],
          'actionability' => finding['actionability'],
          'confidence' => finding['confidence']
        }.compact
      end

      def candidate?(finding)
        return false unless finding

        actionability = finding['actionability'].to_s
        return %w[review_candidate verified_candidate].include?(actionability) if actionability != ''

        %w[unreachable unused].include?(finding['classification'].to_s) &&
          Array(finding['blockers']).empty?
      end

      def graph_node(graph, definition_id)
        Array(graph['nodes']).find { |node| node['definition_id'].to_s == definition_id.to_s }
      end

      def difference_ids(left, right)
        left_ids = Array(left).filter_map { |entry| entry['definition_id'] || entry['node_id'] || entry['id'] }
        right_ids = Array(right).filter_map { |entry| entry['definition_id'] || entry['node_id'] || entry['id'] }
        (left_ids - right_ids).sort
      end

      def load_unit_diff(base, head)
        before = Array(base.dig('diagnostics', 'unrooted_load_units', 'units'))
        after = Array(head.dig('diagnostics', 'unrooted_load_units', 'units'))
        (after - before).sort_by(&:to_s)
      end

      def dispatch_changes(base_graph, head_graph)
        statuses = lambda do |graph|
          Array(graph['resolutions']).to_h do |record|
            resolution = record['resolution'] || record
            [resolution['call_site_id'], resolution['status']]
          end
        end
        before = statuses.call(base_graph)
        after = statuses.call(head_graph)
        after.filter_map do |call_site_id, status|
          next unless %w[partial unknown].include?(status.to_s)
          next unless before[call_site_id].to_s == 'complete'

          { 'call_site_id' => call_site_id, 'from' => before[call_site_id], 'to' => status }
        end.sort_by { |change| change['call_site_id'].to_s }
      end

      def health_change(base, head)
        before = base.fetch('analysis_health', {}).fetch('status', 'unknown')
        after = head.fetch('analysis_health', {}).fetch('status', 'unknown')
        return {} if before == after

        { 'from' => before, 'to' => after }
      end

      def public_surface_changes(base_graph, head_graph)
        fields = lambda do |graph|
          Array(graph['nodes']).filter_map do |node|
            next unless %w[public protected].include?(node['visibility'].to_s)

            [node['definition_id'], node['symbol_id'], node['visibility']]
          end.to_h
        end
        before = fields.call(base_graph)
        after = fields.call(head_graph)
        {
          'added' => (after.keys - before.keys).sort,
          'removed' => (before.keys - after.keys).sort,
          'visibility_changed' => (before.keys & after.keys).filter_map do |key|
            next if before[key] == after[key]

            { 'definition_id' => key, 'from' => before[key], 'to' => after[key] }
          end.sort_by { |change| change['definition_id'].to_s }
        }
      end

      def runtime_evidence_invalidated(base, head)
        before = base.dig('source_snapshot', 'verification', 'status')
        after = head.dig('source_snapshot', 'verification', 'status')
        return {} unless before == 'match' && after != 'match'

        { 'from' => before, 'to' => after }
      end

      def report_identity(report)
        report.dig('artifact_provenance', 'producer') || {}
      end

      def sort_key(finding)
        [finding['file'].to_s, finding['line'].to_i, finding['definition_id'].to_s]
      end
    end
  end
end
