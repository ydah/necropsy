# frozen_string_literal: true

require 'digest'
require 'json'

module Necropsy
  module Bench
    # Builds a deterministic, explicitly-unreviewed queue from normalized reports.
    # The queue is evidence collection tooling; it never supplies labels or passes
    # the public claim gate by itself.
    class ReviewQueue
      ACTIONABLE_STATES = %w[unreachable unused candidate].freeze
      HIGH_CONFIDENCES = %w[high certain].freeze
      CONFIDENCE_ORDER = { 'certain' => 0, 'high' => 1, 'medium' => 2, 'low' => 3 }.freeze
      VERSION = 1

      def initialize(reports:, target_reviewed_high: 300, limit: nil)
        @reports = reports
        @target_reviewed_high = Integer(target_reviewed_high)
        @limit = limit.nil? ? @target_reviewed_high : Integer(limit)
        validate_options!
      rescue ArgumentError, TypeError
        raise Error, 'Review queue target and limit must be integers'
      end

      def call
        validate_reports!
        available = actionable_entries
        entries = available.sort_by { |entry| sort_key(entry) }.first(limit)
        high_entries = entries.select { |entry| HIGH_CONFIDENCES.include?(entry.fetch('confidence')) }
        {
          'schema_version' => VERSION,
          'status' => 'pending',
          'selection' => 'actionable findings, confidence ascending, then corpus and identity',
          'target_reviewed_high_candidates' => target_reviewed_high,
          'available_actionable_candidates' => available.length,
          'queued_candidates' => entries.length,
          'reviewed_candidates' => 0,
          'reviewed_high_candidates' => 0,
          'pending_candidates' => entries.length,
          'pending_high_candidates' => high_entries.length,
          'target_shortfall' => [target_reviewed_high - high_entries.length, 0].max,
          'claim_gate_passed' => false,
          'corpora' => corpus_summary(available, entries),
          'provenance' => provenance,
          'entries' => entries
        }
      end

      private

      attr_reader :reports, :target_reviewed_high, :limit

      def validate_options!
        raise Error, 'Review queue target must be positive' unless target_reviewed_high.positive?
        raise Error, 'Review queue limit must be positive' unless limit.positive?
      end

      def validate_reports!
        raise Error, 'Review queue reports must be a mapping' unless reports.is_a?(Hash)

        reports.each do |corpus, report|
          raise Error, 'Review queue corpus names must be non-empty strings' if corpus.to_s.empty?
          raise Error, "Review queue report #{corpus} must contain findings" unless
            report.is_a?(Hash) && report['findings'].is_a?(Array)
        end
      end

      def actionable_entries
        report_pairs.flat_map do |corpus, report|
          report.fetch('findings').filter_map do |finding|
            next unless actionable?(finding)

            {
              'corpus' => corpus.to_s,
              'id' => finding.fetch('id').to_s,
              'definition_id' => finding['definition_id'],
              'path' => finding['path'],
              'line' => finding['line'],
              'end_line' => finding['end_line'],
              'loc' => finding['loc'],
              'state' => finding.fetch('state').to_s,
              'confidence' => finding.fetch('confidence').to_s,
              'category' => finding['category'].to_s,
              'status' => 'pending',
              'review_class' => review_class(finding)
            }.compact
          end
        end
      end

      def actionable?(finding)
        finding['candidate'] == true || ACTIONABLE_STATES.include?(finding['state'].to_s)
      end

      def review_class(finding)
        return 'high_candidate' if HIGH_CONFIDENCES.include?(finding['confidence'].to_s)

        'candidate'
      end

      def sort_key(entry)
        [
          CONFIDENCE_ORDER.fetch(entry.fetch('confidence'), CONFIDENCE_ORDER.length),
          entry.fetch('corpus'),
          entry.fetch('category'),
          entry.fetch('id'),
          entry['definition_id'].to_s
        ]
      end

      def corpus_summary(available, entries)
        available_by_corpus = available.group_by { |entry| entry.fetch('corpus') }
        reports.keys.map(&:to_s).sort.to_h do |corpus|
          available_entries = available_by_corpus.fetch(corpus, [])
          queued = entries.select { |entry| entry.fetch('corpus') == corpus }
          [corpus, {
            'available_candidates' => available_entries.length,
            'queued_candidates' => queued.length,
            'queued_high_candidates' => queued.count { |entry| HIGH_CONFIDENCES.include?(entry.fetch('confidence')) }
          }]
        end
      end

      def provenance
        report_pairs.to_h do |corpus, report|
          canonical = canonicalize(report)
          [corpus.to_s, {
            'sha256' => Digest::SHA256.hexdigest(JSON.generate(canonical)),
            'finding_count' => report.fetch('findings').length
          }]
        end
      end

      def report_pairs
        reports.to_a.sort_by { |corpus, _report| corpus.to_s }
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            [key, canonicalize(value.fetch(original))]
          end
        when Array
          value.map { |item| canonicalize(item) }
        else
          value
        end
      end
    end
  end
end
