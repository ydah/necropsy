# frozen_string_literal: true

require 'digest'
require 'date'
require 'yaml'

module Necropsy
  module Bench
    class CandidateUnion
      LABELS = %w[dead alive external unknown].freeze
      HIGH_CONFIDENCES = %w[high certain].freeze
      MAX_ENTRIES = 100_000
      MAX_INPUT_BYTES = 16 * 1024 * 1024
      MAX_STRING_BYTES = 4_096

      def initialize(manifest:, repository_root:, reports:, diagnostics:)
        @manifest = manifest
        @repository_root = repository_root
        @reports = reports
        @diagnostics = diagnostics
      end

      def call
        validate_inputs!
        load_necropsy_candidates
        load_external_candidates
        discard_diagnostic_only_rows
        apply_labels
        fill_tool_results
        result = {
          'schema_version' => 1,
          'tool_runs' => tool_runs.sort.to_h,
          'summary' => summary,
          'identity' => {
            'primary' => 'definition_id',
            'legacy_fallback' => 'id',
            'legacy_mapping' => 'logical candidates and labels apply to every matching physical definition'
          },
          'candidates' => candidates.values.sort_by { |candidate| candidate_sort_key(candidate) }
        }
        validate_result!(result)
        result
      end

      private

      attr_reader :manifest, :repository_root, :reports, :diagnostics

      def validate_inputs!
        raise Error, 'Benchmark manifest must be a mapping' unless manifest.is_a?(Hash)
        raise Error, 'Normalized reports must be a mapping' unless reports.is_a?(Hash)
        raise Error, "Benchmark reports exceed #{MAX_ENTRIES} corpora" if reports.length > MAX_ENTRIES

        reports.each do |corpus, report|
          validate_identifier!(corpus, 'corpus')
          validate_mapping!(report, "report #{corpus}")
          validate_array!(report['findings'], "report #{corpus} findings")
          report['findings'].each { |finding| validate_finding!(finding, corpus) }
          identities = report['findings'].map { |finding| finding_identity(finding) }
          duplicate = identities.tally.find { |_identity, count| count > 1 }
          raise Error, "report #{corpus} has duplicate candidate identity #{duplicate.first}" if duplicate
        end
      end

      def validate_finding!(finding, corpus)
        validate_mapping!(finding, "report #{corpus} finding")
        validate_identifier!(finding['id'], "report #{corpus} finding id")
        validate_identifier!(finding['definition_id'], 'definition_id') if finding.key?('definition_id')
      end

      def candidates
        @candidates ||= {}
      end

      def tool_runs
        @tool_runs ||= {
          'necropsy' => {
            'status' => 'generated',
            'version' => manifest.dig('tools', 'necropsy', 'version'),
            'provenance' => { 'kind' => 'generated_normalized_report' }
          }.compact
        }
      end

      def load_necropsy_candidates
        reports.each do |corpus, report|
          report.fetch('findings').each do |finding|
            candidate = candidate_for(corpus, finding_identity(finding), finding)
            actionable = finding.fetch('candidate') { actionable_state?(finding.fetch('state')) }
            candidate['tool_results']['necropsy'] = {
              'candidate' => actionable,
              'diagnostic' => !actionable,
              'state' => finding.fetch('state'),
              'confidence' => finding.fetch('confidence'),
              'category' => finding['category'],
              'loc' => finding['loc'],
              'unknown' => finding['unknown'],
              'rule_hits' => finding['rule_hits'],
              'risk_flags' => finding['risk_flags']
            }.compact
          end
        end
      end

      def actionable_state?(state)
        %w[unreachable unused candidate].include?(state.to_s)
      end

      def discard_diagnostic_only_rows
        candidates.delete_if do |_key, candidate|
          candidate.fetch('tool_results').values.none? { |result| result['candidate'] == true }
        end
      end

      def candidate_source_fields(source)
        {
          'path' => source['path'],
          'line' => source['line'],
          'end_line' => source['end_line'],
          'loc' => source['loc'],
          'category' => source['category']
        }.compact
      end

      def merge_candidate_source(candidate, source)
        candidate_source_fields(source).each do |key, value|
          candidate[key] = value unless candidate.key?(key)
        end
      end

      def tool_metrics
        tool_runs.sort.to_h do |tool, run|
          next [tool, { 'status' => 'skipped' }] if run['status'] == 'skipped'

          selected = candidates.values.select { |candidate| candidate.dig('tool_results', tool, 'candidate') == true }
          [tool, candidate_metrics(selected)]
        end
      end

      def candidate_metrics(selected)
        reviewed = selected.select { |candidate| determinate_label?(candidate) }
        true_positives = reviewed.count { |candidate| candidate.dig('label', 'value') == 'dead' }
        known_positives = known_positive_entries
        recalled = known_positives.count { |candidate| known_positive_recalled?(candidate, selected) }
        measured_loc = selected.filter_map { |candidate| candidate['loc'] }
        {
          'candidate_precision' => reviewed.empty? ? nil : ratio(true_positives, reviewed.length),
          'precision_status' => precision_status(selected, reviewed),
          'candidate_count' => selected.length,
          'candidate_loc' => measured_loc.sum,
          'candidate_loc_measured_count' => measured_loc.length,
          'reviewed_high_candidate_count' => reviewed_high_candidate_count(selected),
          'known_positive_recall' => known_positives.empty? ? nil : ratio(recalled, known_positives.length),
          'known_positive_count' => known_positives.length,
          'reviewed_candidate_count' => reviewed.length,
          'by_category' => category_metrics(selected, known_positives),
          'by_corpus' => corpus_metrics(selected, known_positives),
          'macro_average' => macro_average(selected, known_positives)
        }
      end

      def corpus_metrics(selected, known_positives)
        corpora = (selected + known_positives).map { |candidate| candidate.fetch('corpus') }.uniq.sort
        corpora.to_h do |corpus|
          corpus_selected = selected.select { |candidate| candidate['corpus'] == corpus }
          corpus_reviewed = corpus_selected.select { |candidate| determinate_label?(candidate) }
          corpus_known = known_positives.select { |candidate| candidate['corpus'] == corpus }
          true_positives = corpus_reviewed.count { |candidate| candidate.dig('label', 'value') == 'dead' }
          recalled = corpus_known.count { |candidate| known_positive_recalled?(candidate, corpus_selected) }
          [corpus, {
            'candidate_precision' => corpus_reviewed.empty? ? nil : ratio(true_positives, corpus_reviewed.length),
            'known_positive_recall' => corpus_known.empty? ? nil : ratio(recalled, corpus_known.length),
            'candidate_count' => corpus_selected.length,
            'reviewed_candidate_count' => corpus_reviewed.length,
            'known_positive_count' => corpus_known.length
          }]
        end
      end

      def macro_average(selected, known_positives)
        rows = corpus_metrics(selected, known_positives).values
        precision = rows.filter_map { |row| row['candidate_precision'] }
        recall = rows.filter_map { |row| row['known_positive_recall'] }
        {
          'candidate_precision' => mean(precision),
          'candidate_precision_corpora' => precision.length,
          'known_positive_recall' => mean(recall),
          'known_positive_recall_corpora' => recall.length
        }
      end

      def mean(values)
        return if values.empty?

        ratio(values.sum, values.length)
      end

      def category_metrics(selected, known_positives)
        categories = (selected + known_positives).map { |candidate| category_for(candidate) }.uniq.sort
        categories.to_h do |category|
          category_selected = selected.select { |candidate| category_for(candidate) == category }
          category_reviewed = category_selected.select { |candidate| determinate_label?(candidate) }
          category_known = known_positives.select { |candidate| category_for(candidate) == category }
          true_positives = category_reviewed.count { |candidate| candidate.dig('label', 'value') == 'dead' }
          recalled = category_known.count { |candidate| known_positive_recalled?(candidate, category_selected) }
          measured_loc = category_selected.filter_map { |candidate| candidate['loc'] }
          [category, {
            'candidate_precision' => category_reviewed.empty? ? nil : ratio(true_positives, category_reviewed.length),
            'precision_status' => precision_status(category_selected, category_reviewed),
            'candidate_count' => category_selected.length,
            'candidate_loc' => measured_loc.sum,
            'candidate_loc_measured_count' => measured_loc.length,
            'reviewed_high_candidate_count' => reviewed_high_candidate_count(category_selected),
            'known_positive_recall' => category_known.empty? ? nil : ratio(recalled, category_known.length),
            'known_positive_count' => category_known.length
          }]
        end
      end

      def category_for(candidate)
        value = candidate.dig('label', 'category') || candidate['category']
        value.to_s.empty? ? 'uncategorized' : value.to_s
      end

      def candidate_key(candidate)
        [candidate['corpus'], candidate['definition_id'] || candidate['id']]
      end

      def candidate_sort_key(candidate)
        [candidate['corpus'], candidate['id'], candidate['definition_id'].to_s]
      end

      def finding_identity(finding)
        finding['definition_id'] || "logical:#{finding.fetch('id')}"
      end

      def candidates_matching(corpus, entry)
        definition_id = entry['definition_id']
        return [candidates[[corpus, definition_id]]].compact if definition_id

        candidates.values.select { |candidate| candidate['corpus'] == corpus && candidate['id'] == entry['id'] }
      end

      def known_positive_recalled?(known_positive, selected)
        selected.any? do |candidate|
          next false unless candidate['corpus'] == known_positive['corpus']

          if known_positive['definition_id']
            candidate['definition_id'] == known_positive['definition_id']
          else
            candidate['id'] == known_positive['id']
          end
        end
      end

      def known_positive_entries
        return @known_positive_entries if defined?(@known_positive_entries) && @known_positive_entries

        candidates.values.select { |candidate| candidate.dig('label', 'value') == 'dead' }
      end

      def determinate_label?(candidate)
        %w[dead alive external].include?(candidate.dig('label', 'value'))
      end

      def reviewed_high_candidate_count(selected)
        selected.count do |candidate|
          HIGH_CONFIDENCES.include?(candidate.dig('tool_results', 'necropsy', 'confidence').to_s) &&
            determinate_label?(candidate)
        end
      end

      def precision_status(selected, reviewed)
        return 'no_candidates' if selected.empty?
        return 'unreviewed' if reviewed.empty?

        'measured'
      end

      def ratio(numerator, denominator)
        (numerator.to_f / denominator).round(4)
      end

      def necropsy_diagnostics
        by_corpus = reports.sort.to_h do |corpus, report|
          [corpus, report['quality'] || legacy_quality(report)]
        end
        {
          'by_corpus' => by_corpus,
          'aggregate' => aggregate_quality(by_corpus.values)
        }
      end

      def legacy_quality(report)
        findings = report.fetch('findings')
        blocked = findings.count { |finding| finding['state'] == 'blocked' }
        {
          'candidate_count' => findings.count { |finding| actionable_state?(finding['state']) },
          'candidate_loc' => findings.filter_map { |finding| finding['loc'] }.sum,
          'diagnostic_count' => findings.count { |finding| !actionable_state?(finding['state']) },
          'blocked_count' => blocked,
          'blocked_rate' => findings.empty? ? 0.0 : ratio(blocked, findings.length),
          'unknown_finding_count' => findings.count { |finding| finding['unknown'] },
          'unknown_finding_rate' => 0.0,
          'resolution_counts' => { 'total' => 0, 'complete' => 0, 'partial' => 0, 'unknown' => 0 },
          'unknown_resolution_rate' => 0.0,
          'rule_counts' => {},
          'risk_counts' => {},
          'by_category' => {}
        }
      end

      def aggregate_quality(quality_rows)
        totals = %w[candidate_count candidate_loc diagnostic_count blocked_count unknown_finding_count].to_h do |key|
          [key, quality_rows.sum { |quality| quality.fetch(key, 0) }]
        end
        finding_total = totals.fetch('candidate_count') + totals.fetch('diagnostic_count')
        resolution_total = quality_rows.sum { |quality| quality.dig('resolution_counts', 'total').to_i }
        unknown_resolutions = quality_rows.sum { |quality| quality.dig('resolution_counts', 'unknown').to_i }
        totals.merge(
          'blocked_rate' => finding_total.zero? ? 0.0 : ratio(totals.fetch('blocked_count'), finding_total),
          'unknown_finding_rate' => finding_total.zero? ? 0.0 : ratio(totals.fetch('unknown_finding_count'), finding_total),
          'unknown_resolution_rate' => resolution_total.zero? ? 0.0 : ratio(unknown_resolutions, resolution_total),
          'rule_counts' => merge_counts(quality_rows, 'rule_counts'),
          'risk_counts' => merge_counts(quality_rows, 'risk_counts')
        )
      end

      def merge_counts(rows, key)
        rows.each_with_object(Hash.new(0)) do |row, counts|
          row.fetch(key, {}).each { |name, count| counts[name] += count }
        end.sort.to_h
      end

      def load_external_candidates
        manifest.fetch('tools', {}).sort.each do |tool, definition|
          next if tool == 'necropsy'

          path = snapshot_path(definition)
          unless path && File.file?(path)
            skip_tool(tool, definition)
            next
          end

          validate_file_size!(path, "#{tool} candidate snapshot")
          payload = YAML.safe_load_file(path, aliases: false)
          validate_snapshot!(payload, tool)
          payload.fetch('candidates').each do |entry|
            validate_external_candidate!(entry, tool)
            matches = candidates_matching(entry.fetch('corpus'), entry)
            matches = [candidate_for(entry.fetch('corpus'), finding_identity(entry), entry)] if matches.empty?
            matches.each do |candidate|
              candidate['tool_results'][tool] = {
                'candidate' => true,
                'classification' => entry['classification'] || 'candidate',
                'identity_match' => entry['definition_id'] ? 'physical' : 'legacy_logical_fallback'
              }
            end
          end
          tool_runs[tool] = {
            'status' => 'snapshot',
            'version' => definition['version'],
            'snapshot_sha256' => Digest::SHA256.file(path).hexdigest,
            'provenance' => payload['provenance']
          }.compact
        rescue KeyError, Psych::Exception => e
          raise Error, "Invalid #{tool} candidate snapshot: #{e.message}"
        end
      end

      def snapshot_path(definition)
        env_path = ENV[definition['snapshot_env'].to_s] if definition['snapshot_env']
        relative = env_path || definition['snapshot']
        File.expand_path(relative, repository_root) if relative && !relative.empty?
      end

      def validate_snapshot!(payload, tool)
        validate_mapping!(payload, "#{tool} candidate snapshot")
        raise Error, 'schema_version must be 1' unless payload['schema_version'] == 1
        raise Error, "tool must be #{tool}" unless payload['tool'] == tool

        validate_array!(payload['candidates'], "#{tool} candidates")

        provenance = payload['provenance']
        raise Error, 'provenance must be a non-empty mapping' unless provenance.is_a?(Hash) && !provenance.empty?
      end

      def validate_external_candidate!(entry, tool)
        validate_mapping!(entry, "#{tool} candidate")
        validate_identifier!(entry['corpus'], "#{tool} candidate corpus")
        validate_identifier!(entry['id'], "#{tool} candidate id")
        validate_identifier!(entry['definition_id'], "#{tool} candidate definition_id") if entry.key?('definition_id')
      end

      def skip_tool(tool, definition)
        command = Array(definition['command']).first || tool
        reason = if executable?(command)
                   'candidate snapshot unavailable; live adapter is intentionally disabled for reproducibility'
                 else
                   "candidate snapshot unavailable and executable #{command.inspect} was not found"
                 end
        message = "#{tool} skipped: #{reason}"
        diagnostics << message
        tool_runs[tool] = { 'status' => 'skipped', 'diagnostic' => message, 'version' => definition['version'] }
      end

      def executable?(command)
        return File.executable?(command) if command.include?(File::SEPARATOR)

        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
          File.executable?(File.join(directory, command))
        end
      end

      def candidate_for(corpus, id, source)
        key = [corpus, id]
        candidate = candidates[key] ||= {
          'corpus' => corpus,
          'id' => source.fetch('id'),
          'definition_id' => source['definition_id'],
          'tool_results' => {}
        }.compact
        merge_candidate_source(candidate, source)
        candidate
      end

      def apply_labels
        path = File.expand_path(manifest.fetch('labels'), repository_root)
        validate_file_size!(path, 'benchmark labels')
        payload = YAML.safe_load_file(path, aliases: false)
        validate_mapping!(payload, 'benchmark labels')
        labels = payload['labels']
        validate_array!(labels, 'benchmark labels')
        load_known_positives(payload)
        minimum = Integer(manifest.fetch('minimum_reviewed_labels', 30))
        raise Error, "Benchmark seed requires at least #{minimum} reviewed labels" if labels.length < minimum

        labels.each do |entry|
          reviewed_at = entry['reviewed_at'] || payload['reviewed_at']
          source_revision = entry['source_revision'] || manifest.dig('corpora', entry['corpus'], 'revision')
          validate_label(entry, reviewed_at: reviewed_at, source_revision: source_revision)
          key = [entry.fetch('corpus'), entry['definition_id'] || entry.fetch('id')]
          matches = candidates_matching(entry.fetch('corpus'), entry)
          raise Error, "Benchmark label does not match a tool candidate: #{key.join(':')}" if matches.empty?

          matches.each do |candidate|
            raise Error, "Duplicate benchmark label: #{key.join(':')}" if candidate.key?('label')

            candidate['label'] = entry.slice('value', 'rationale', 'reviewer', 'category').merge(
              'reviewed_at' => reviewed_at,
              'source_revision' => source_revision,
              'identity_match' => entry['definition_id'] ? 'physical' : 'legacy_logical_fallback'
            ).compact
          end
        end
      rescue KeyError, ArgumentError, Psych::Exception => e
        raise Error, "Invalid benchmark labels: #{e.message}"
      end

      def load_known_positives(payload)
        return unless payload.key?('known_positives')

        entries = payload['known_positives']
        validate_array!(entries, 'known-positive entries')
        @known_positive_entries = entries.map do |entry|
          validate_mapping!(entry, 'known-positive entry')

          normalized = entry.transform_keys(&:to_s).slice('corpus', 'id', 'definition_id', 'category', 'rationale')
          raise Error, 'Known-positive entries require corpus and id' if %w[corpus id].any? do |key|
            normalized[key].to_s.empty?
          end

          validate_identifier!(normalized['corpus'], 'known-positive corpus')
          validate_identifier!(normalized['id'], 'known-positive id')
          validate_identifier!(normalized['definition_id'], 'known-positive definition_id') if normalized['definition_id']
          raise Error, "Known positive #{candidate_key(normalized).join(':')} requires a rationale" if
            normalized['rationale'].to_s.strip.empty?

          normalized
        end
        duplicate = @known_positive_entries.map { |entry| candidate_key(entry) }.tally.find { |_key, count| count > 1 }
        raise Error, "Duplicate known positive: #{duplicate.first.join(':')}" if duplicate
      end

      def validate_label(entry, reviewed_at:, source_revision:)
        validate_mapping!(entry, 'benchmark label')
        validate_identifier!(entry['corpus'], 'benchmark label corpus')
        validate_identifier!(entry['id'], 'benchmark label id')
        validate_identifier!(entry['definition_id'], 'benchmark label definition_id') if entry.key?('definition_id')
        value = entry.fetch('value')
        raise Error, "Invalid benchmark label #{value.inspect}" unless LABELS.include?(value)
        raise Error, "Benchmark label #{entry['id']} requires a rationale" if entry['rationale'].to_s.strip.empty?
        return unless manifest['label_provenance_required'] == true

        raise Error, "Benchmark label #{entry['id']} requires a reviewer" if entry['reviewer'].to_s.strip.empty?
        raise Error, "Benchmark label #{entry['id']} requires reviewed_at" if reviewed_at.to_s.strip.empty?
        raise Error, "Benchmark label #{entry['id']} requires source_revision" if source_revision.to_s.strip.empty?

        Date.iso8601(reviewed_at.to_s)
      rescue Date::Error
        raise Error, "Benchmark label #{entry['id']} reviewed_at must be an ISO 8601 date"
      end

      def validate_mapping!(value, label)
        raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)
      end

      def validate_array!(value, label)
        raise Error, "#{label} must be an array" unless value.is_a?(Array)
        raise Error, "#{label} exceeds #{MAX_ENTRIES} entries" if value.length > MAX_ENTRIES
      end

      def validate_identifier!(value, label)
        raise Error, "#{label} must be a non-empty string" unless value.is_a?(String) && !value.empty?
        raise Error, "#{label} exceeds #{MAX_STRING_BYTES} bytes" if value.bytesize > MAX_STRING_BYTES
      end

      def validate_file_size!(path, label)
        raise Error, "#{label} exceeds #{MAX_INPUT_BYTES} bytes" if File.size(path) > MAX_INPUT_BYTES
      end

      def fill_tool_results
        candidates.each_value do |candidate|
          tool_runs.each do |tool, run|
            result = { 'candidate' => false }
            result = { 'candidate' => nil, 'status' => 'skipped' } if run['status'] == 'skipped'
            candidate['tool_results'][tool] ||= result
          end
          candidate['tool_results'] = candidate['tool_results'].sort.to_h
        end
      end

      def summary
        labels = candidates.values.filter_map { |candidate| candidate.dig('label', 'value') }
        {
          'candidates' => candidates.length,
          'reviewed' => labels.length,
          'by_label' => labels.tally.sort.to_h,
          'tool_metrics' => tool_metrics,
          'necropsy_diagnostics' => necropsy_diagnostics
        }
      end

      def validate_result!(result)
        tools = result.fetch('tool_runs').keys
        result.fetch('candidates').each do |candidate|
          actual_tools = candidate.fetch('tool_results').keys
          next if actual_tools == tools

          raise Error, "Candidate #{candidate['corpus']}:#{candidate['id']} has incomplete tool results"
        end
      end
    end
  end
end
