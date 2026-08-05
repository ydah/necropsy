# frozen_string_literal: true

require 'yaml'
require 'time'

module Necropsy
  module Guardrail
    class Baseline
      SCHEMA_VERSION = 2
      MIGRATION_SCHEMA_VERSION = 1

      Comparison = Data.define(:matched_findings, :new_findings, :ambiguities, :review_report) do
        def review_required?
          ambiguities.any?
        end
      end

      attr_reader :path, :fingerprints, :schema_version

      def self.load(path)
        return new(path: path, findings: []) unless File.exist?(path)

        payload = YAML.safe_load_file(path, aliases: false)
        payload = {} if payload.nil?
        raise Error, 'Baseline must contain a YAML mapping' unless payload.is_a?(Hash)

        schema_version = schema_version_from(payload)
        findings = payload.fetch('findings', [])
        raise Error, 'Baseline findings must be an array' unless findings.is_a?(Array)

        new(path: path, findings: findings, schema_version: schema_version)
      end

      def self.schema_version_from(payload)
        explicit = normalize_schema_version(payload['schema_version']) if payload.key?('schema_version')
        legacy = normalize_schema_version(payload['version']) if payload.key?('version')
        raise Error, "Conflicting baseline schema versions: #{explicit} and #{legacy}" if explicit && legacy && explicit != legacy

        explicit || legacy || 1
      end
      private_class_method :schema_version_from

      def self.normalize_schema_version(value)
        normalized = if value.is_a?(Integer)
                       value
                     elsif value.is_a?(String) && value.match?(/\A[0-9]+\z/)
                       value.to_i
                     end
        raise Error, "Invalid baseline schema version: #{value.inspect}" unless normalized

        normalized
      end
      private_class_method :normalize_schema_version

      def self.write(report, path:)
        findings = report.dead_methods(min_confidence: :low).map do |finding|
          {
            'fingerprint' => finding.physical_fingerprint,
            'logical_fingerprint' => finding.logical_fingerprint,
            'classification' => finding.classification.to_s,
            'confidence' => finding.confidence.to_s,
            'node_id' => finding.node.id,
            'symbol_id' => finding.node.symbol_id,
            'definition_id' => finding.node.definition_id,
            'body_digest' => finding.node.body_digest,
            'file' => finding.node.file,
            'line' => finding.node.line
          }
        end
        payload = {
          'schema_version' => SCHEMA_VERSION,
          'version' => SCHEMA_VERSION,
          'identity' => 'physical_definition',
          'generated_at' => Time.now.utc.iso8601,
          'findings' => findings
        }
        File.write(path, payload.to_yaml)
      end

      def initialize(path:, findings:, schema_version: 1)
        @path = path
        @schema_version = normalize_schema_version(schema_version)
        raise Error, "Unsupported baseline schema version: #{@schema_version}" unless [1, SCHEMA_VERSION].include?(@schema_version)

        @findings = findings.map do |finding|
          raise Error, 'Baseline findings must be mappings' unless finding.is_a?(Hash)

          finding.transform_keys(&:to_s).tap { |entry| validate_entry!(entry) }
        end
        @fingerprints = @findings.filter_map { |finding| finding['fingerprint'] }.to_set
      end

      def include?(finding)
        fingerprint = schema_version == SCHEMA_VERSION ? finding.physical_fingerprint : finding.logical_fingerprint
        fingerprints.include?(fingerprint)
      end

      def compare(findings)
        current = findings.sort_by { |finding| [finding.node.file, finding.node.line, finding.node.definition_id] }
        assignments = {}
        ambiguities = []

        @findings.each_with_index do |entry, index|
          resolution = resolve_entry(entry, current)
          next if resolution[:candidates].empty?

          if resolution[:candidates].one? && !assignments.value?(resolution[:candidates].first)
            assignments[index] = resolution[:candidates].first
          else
            ambiguities << ambiguity(entry, index, resolution, assignments)
          end
        end

        matched = assignments.values.uniq
        Comparison.new(
          matched_findings: matched,
          new_findings: current - matched,
          ambiguities: ambiguities,
          review_report: migration_review_report(ambiguities)
        )
      end

      def count_at_least(confidence)
        threshold = CONFIDENCE_LEVELS.fetch(confidence)
        @findings.count do |finding|
          level = finding['confidence']&.to_sym
          level && CONFIDENCE_LEVELS.fetch(level, -1) >= threshold
        end
      end

      private

      def normalize_schema_version(value)
        self.class.send(:normalize_schema_version, value)
      end

      def resolve_entry(entry, current)
        return resolve_v1_entry(entry, current) if schema_version == 1

        candidates = current.select { |finding| same_classification?(entry, finding) }
        strategies(entry).each do |strategy, value|
          next if value.nil? || value.to_s.empty?

          matches = candidates.select { |finding| strategy_match?(strategy, value, entry, finding) }
          return { strategy: strategy, candidates: matches } unless matches.empty?
        end
        { strategy: 'unmatched', candidates: [] }
      end

      def resolve_v1_entry(entry, current)
        identity_matches = if present?(symbol_hint(entry))
                             current.select { |finding| symbol_path_match?(entry, finding) }
                           else
                             []
                           end
        return { strategy: 'logical_identity', candidates: identity_matches } if identity_matches.length > 1

        if present?(entry['fingerprint'])
          fingerprint_matches = current.select { |finding| finding.logical_fingerprint == entry['fingerprint'] }
          return { strategy: 'logical_fingerprint', candidates: fingerprint_matches } unless fingerprint_matches.empty?

          return { strategy: 'unmatched', candidates: [] }
        end

        matches = identity_matches.select { |finding| same_classification?(entry, finding) }
        matches.empty? ? { strategy: 'unmatched', candidates: [] } : { strategy: 'symbol_path_hint', candidates: matches }
      end

      def strategies(entry)
        exact = entry['definition_id']
        exact ||= entry['fingerprint'] if schema_version == SCHEMA_VERSION
        [
          ['exact', exact],
          ['body_digest', entry['body_digest']],
          ['logical_fingerprint', entry['fingerprint']],
          ['symbol_path_hint', symbol_hint(entry)]
        ]
      end

      def strategy_match?(strategy, value, entry, finding)
        case strategy
        when 'exact'
          finding.node.definition_id == value || finding.physical_fingerprint == value
        when 'body_digest'
          finding.node.body_digest == value
        when 'logical_fingerprint'
          schema_version == 1 && finding.logical_fingerprint == value
        when 'symbol_path_hint'
          symbol_path_match?(entry, finding)
        end
      end

      def symbol_path_match?(entry, finding)
        symbol = symbol_hint(entry)
        return false unless symbol == finding.node.symbol_id

        path = entry['file']
        path.nil? || path.empty? || path == finding.node.file
      end

      def symbol_hint(entry)
        entry['symbol_id'] || entry['node_id']
      end

      def validate_entry!(entry)
        string_fields = %w[
          fingerprint logical_fingerprint classification confidence node_id symbol_id definition_id body_digest file
        ]
        string_fields.each do |field|
          value = entry[field]
          raise Error, "Baseline #{field} must be a string" unless value.nil? || value.is_a?(String)
        end
        line = entry['line']
        raise Error, 'Baseline line must be a positive integer' unless line.nil? || (line.is_a?(Integer) && line.positive?)

        validate_v1_fingerprint!(entry) if schema_version == 1
        validate_v2_fingerprints!(entry) if schema_version == SCHEMA_VERSION
      end

      def validate_v1_fingerprint!(entry)
        return unless present?(entry['fingerprint']) && present?(entry['classification']) && present?(symbol_hint(entry))

        expected = logical_fingerprint(entry.fetch('classification'), symbol_hint(entry))
        raise Error, 'Baseline v1 fingerprint contradicts its classification or symbol' unless entry['fingerprint'] == expected
      end

      def validate_v2_fingerprints!(entry)
        raise Error, 'Baseline v2 entries require classification' unless present?(entry['classification'])

        identity_fields = [entry['fingerprint'], entry['definition_id'], entry['body_digest'], symbol_hint(entry)]
        raise Error, 'Baseline v2 entries require a physical identity or migration hint' unless identity_fields.any? { present?(_1) }

        if present?(entry['fingerprint']) && present?(entry['definition_id'])
          expected = physical_fingerprint(entry.fetch('classification'), entry.fetch('definition_id'))
          raise Error, 'Baseline v2 fingerprint contradicts its classification or definition' unless entry['fingerprint'] == expected
        end
        return unless present?(entry['logical_fingerprint']) && present?(entry['classification']) && present?(symbol_hint(entry))

        expected = logical_fingerprint(entry.fetch('classification'), symbol_hint(entry))
        raise Error, 'Baseline logical fingerprint contradicts its classification or symbol' unless entry['logical_fingerprint'] == expected
      end

      def logical_fingerprint(classification, symbol_id)
        Digest::SHA256.hexdigest("#{classification}:#{symbol_id}")
      end

      def physical_fingerprint(classification, definition_id)
        Digest::SHA256.hexdigest("#{classification}:#{definition_id}")
      end

      def present?(value)
        value.is_a?(String) && !value.empty?
      end

      def same_classification?(entry, finding)
        classification = entry['classification']
        classification.nil? || classification == finding.classification.to_s
      end

      def ambiguity(entry, index, resolution, assignments)
        candidates = resolution[:candidates]
        conflicts = assignments.select { |_assigned_index, finding| candidates.include?(finding) }.keys
        {
          'baseline_index' => index,
          'strategy' => resolution[:strategy],
          'reason' => conflicts.empty? ? 'multiple_current_definitions' : 'current_definition_already_matched',
          'conflicting_baseline_indexes' => conflicts,
          'baseline' => baseline_identity(entry),
          'candidates' => candidates.map { |finding| finding_identity(finding) }
        }
      end

      def baseline_identity(entry)
        entry.slice('fingerprint', 'logical_fingerprint', 'classification', 'node_id', 'symbol_id', 'definition_id',
                    'body_digest', 'file', 'line')
      end

      def finding_identity(finding)
        {
          'physical_fingerprint' => finding.physical_fingerprint,
          'classification' => finding.classification.to_s,
          'symbol_id' => finding.node.symbol_id,
          'definition_id' => finding.node.definition_id,
          'body_digest' => finding.node.body_digest,
          'file' => finding.node.file,
          'line' => finding.node.line
        }
      end

      def migration_review_report(ambiguities)
        {
          'schema_version' => MIGRATION_SCHEMA_VERSION,
          'baseline_schema_version' => schema_version,
          'baseline_path' => path,
          'review_required' => ambiguities.any?,
          'ambiguities' => ambiguities
        }
      end
    end
  end
end
