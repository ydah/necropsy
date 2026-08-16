# frozen_string_literal: true

require 'yaml'
require 'time'
require 'tempfile'

module Necropsy
  module Guardrail
    class Baseline
      SCHEMA_VERSION = 2
      MIGRATION_SCHEMA_VERSION = 1
      CLASSIFICATIONS = %w[unreachable unused blocked test_only_reachable].freeze

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

      def self.write(report, path:, clock: Clock.new)
        findings = report.actionable_candidates(min_confidence: :low).map do |finding|
          {
            'fingerprint' => finding.physical_fingerprint,
            'logical_fingerprint' => finding.logical_fingerprint,
            'classification' => finding.classification.to_s,
            'confidence' => finding.confidence.to_s,
            'actionability' => finding.actionability.to_s,
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
          'generated_at' => clock.time.iso8601,
          'findings' => findings
        }
        atomic_write(path, payload.to_yaml)
      end

      def self.atomic_write(path, contents)
        directory = File.dirname(path)
        Tempfile.create([".#{File.basename(path)}", '.tmp'], directory) do |file|
          file.write(contents)
          file.flush
          file.fsync
          file.close
          File.rename(file.path, path)
        end
        File.open(directory, 'rb', &:fsync)
      rescue Errno::EINVAL, Errno::EISDIR
        nil
      end
      private_class_method :atomic_write

      def initialize(path:, findings:, schema_version: 1)
        @path = path
        @schema_version = normalize_schema_version(schema_version)
        raise Error, "Unsupported baseline schema version: #{@schema_version}" unless [1, SCHEMA_VERSION].include?(@schema_version)

        @findings = findings.map do |finding|
          raise Error, 'Baseline findings must be mappings' unless finding.is_a?(Hash)

          finding.transform_keys(&:to_s).tap { |entry| validate_entry!(entry) }
        end
        validate_duplicate_identities!
        @fingerprints = @findings.filter_map { |finding| finding['fingerprint'] }.to_set
      end

      def include?(finding)
        fingerprint = schema_version == SCHEMA_VERSION ? finding.physical_fingerprint : finding.logical_fingerprint
        fingerprints.include?(fingerprint)
      end

      def compare(findings, migration: false)
        current = findings.sort_by { |finding| [finding.node.file, finding.node.line, finding.node.definition_id] }
        current_index = build_current_index(current)
        assignments = {}
        assignment_indexes = {}
        ambiguities = []

        @findings.each_with_index do |entry, index|
          resolution = resolve_entry(entry, current_index, migration: migration)
          if resolution[:review_required]
            ambiguities << ambiguity(entry, index, resolution, assignment_indexes)
            next
          end
          next if resolution[:candidates].empty?

          candidate = resolution[:candidates].first
          candidate_key = candidate&.physical_fingerprint
          if resolution[:candidates].one? && !assignment_indexes.key?(candidate_key)
            assignments[index] = candidate
            assignment_indexes[candidate_key] = index
          else
            ambiguities << ambiguity(entry, index, resolution, assignment_indexes)
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

      def migrate(findings)
        compare(findings, migration: true)
      end

      def count_at_least(confidence)
        if Configuration::CI_ACTIONABILITY_THRESHOLDS.include?(confidence)
          threshold = confidence == :new_verified_candidate ? :verified_candidate : :review_candidate
          return @findings.count do |finding|
            actionability = finding['actionability']&.to_sym || inferred_actionability(finding)
            ACTIONABILITY_LEVELS.fetch(actionability, -1) >= ACTIONABILITY_LEVELS.fetch(threshold)
          end
        end

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

      def resolve_entry(entry, current_index, migration:)
        return resolve_exact_entry(entry, current_index) unless migration
        return resolve_v1_entry(entry, current_index) if schema_version == 1

        strategies(entry).each do |strategy, value|
          next if value.nil? || value.to_s.empty?

          matches = indexed_matches(current_index, strategy, value, entry)
          return { strategy: strategy, candidates: matches } unless matches.empty?
        end
        { strategy: 'unmatched', candidates: [] }
      end

      def resolve_exact_entry(entry, current_index)
        if schema_version == 1
          resolution = resolve_v1_entry(entry, current_index)
          return resolution.merge(review_required: true, reason: 'legacy_baseline_requires_migration')
        end

        value = entry['definition_id'] || entry['fingerprint']
        candidates = indexed_matches(current_index, 'exact', value, entry)
        { strategy: 'exact', candidates: candidates }
      end

      def resolve_v1_entry(entry, current_index)
        identity_matches = if present?(symbol_hint(entry))
                             indexed_symbol_path(current_index, entry)
                           else
                             []
                           end
        return { strategy: 'logical_identity', candidates: identity_matches } if identity_matches.length > 1

        if present?(entry['fingerprint'])
          fingerprint_matches = current_index.fetch(:logical_fingerprint).fetch(entry['fingerprint'], [])
          return { strategy: 'logical_fingerprint', candidates: fingerprint_matches } unless fingerprint_matches.empty?

          return { strategy: 'unmatched', candidates: [] }
        end

        matches = identity_matches.select { |finding| same_classification?(entry, finding) }
        matches.empty? ? { strategy: 'unmatched', candidates: [] } : { strategy: 'symbol_path_hint', candidates: matches }
      end

      def build_current_index(current)
        {
          definition_id: current.group_by { |finding| finding.node.definition_id },
          physical_fingerprint: current.group_by(&:physical_fingerprint),
          logical_fingerprint: current.group_by(&:logical_fingerprint),
          body_digest: current.group_by { |finding| finding.node.body_digest },
          symbol: current.group_by { |finding| finding.node.symbol_id },
          symbol_path: current.group_by { |finding| symbol_path_key_for(finding) }
        }
      end

      def indexed_matches(current_index, strategy, value, entry)
        candidates = case strategy
                     when 'exact'
                       by_definition = current_index.fetch(:definition_id).fetch(value, [])
                       by_fingerprint = current_index.fetch(:physical_fingerprint).fetch(value, [])
                       by_definition + by_fingerprint
                     when 'body_digest'
                       current_index.fetch(:body_digest).fetch(value, []).select do |finding|
                         symbol_path_match?(entry, finding)
                       end
                     when 'symbol_path_hint'
                       indexed_symbol_path(current_index, entry)
                     else
                       []
                     end
        candidates.uniq.select { |finding| same_classification?(entry, finding) }
      end

      def strategies(entry)
        exact = entry['definition_id']
        exact ||= entry['fingerprint'] if schema_version == SCHEMA_VERSION
        [
          ['exact', exact],
          ['body_digest', entry['body_digest']],
          ['symbol_path_hint', symbol_hint(entry)]
        ]
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

      def symbol_path_key(entry)
        [symbol_hint(entry), present?(entry['file']) ? entry['file'] : nil]
      end

      def indexed_symbol_path(current_index, entry)
        return current_index.fetch(:symbol).fetch(symbol_hint(entry), []) unless present?(entry['file'])

        current_index.fetch(:symbol_path).fetch(symbol_path_key(entry), [])
      end

      def symbol_path_key_for(finding)
        [finding.node.symbol_id, finding.node.file]
      end

      def validate_entry!(entry)
        string_fields = %w[
          fingerprint logical_fingerprint classification confidence actionability node_id symbol_id definition_id body_digest file
        ]
        string_fields.each do |field|
          value = entry[field]
          raise Error, "Baseline #{field} must be a string" unless value.nil? || value.is_a?(String)
        end
        line = entry['line']
        raise Error, 'Baseline line must be a positive integer' unless line.nil? || (line.is_a?(Integer) && line.positive?)

        classification = entry['classification']
        raise Error, "Unknown baseline classification: #{classification}" if
          classification && !CLASSIFICATIONS.include?(classification)

        confidence = entry['confidence']
        raise Error, "Unknown baseline confidence: #{confidence}" if
          confidence && !CONFIDENCE_LEVELS.key?(confidence.to_sym)

        actionability = entry['actionability']
        raise Error, "Unknown baseline actionability: #{actionability}" if
          actionability && !ACTIONABILITY_STATES.include?(actionability.to_sym)

        validate_v1_fingerprint!(entry) if schema_version == 1
        validate_v2_fingerprints!(entry) if schema_version == SCHEMA_VERSION
      end

      def validate_duplicate_identities!
        identities = @findings.filter_map do |entry|
          if schema_version == SCHEMA_VERSION && present?(entry['definition_id']) && present?(entry['classification'])
            physical_fingerprint(entry['classification'], entry['definition_id'])
          elsif present?(entry['fingerprint'])
            entry['fingerprint']
          end
        end
        duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
        raise Error, "Duplicate baseline physical identity: #{duplicate}" if duplicate
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

      def inferred_actionability(entry)
        return :review_candidate if %w[unreachable unused].include?(entry['classification'].to_s)

        :diagnostic
      end

      def ambiguity(entry, index, resolution, assignment_indexes)
        candidates = resolution[:candidates]
        conflicts = candidates.filter_map { |finding| assignment_indexes[finding.physical_fingerprint] }.uniq.sort
        {
          'baseline_index' => index,
          'strategy' => resolution[:strategy],
          'reason' => resolution[:reason] ||
            (conflicts.empty? ? 'multiple_current_definitions' : 'current_definition_already_matched'),
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
