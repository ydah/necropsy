# frozen_string_literal: true

module Necropsy
  class Reporter
    FORMATS = %i[human json yaml yml sarif github annotations].freeze
    DEFAULT_MIN_CONFIDENCE = :medium
    DEFINITION_RESOLUTION_SAMPLE_LIMIT = 5

    def initialize(report)
      @report = report
    end

    def render(format: :human, min_confidence: DEFAULT_MIN_CONFIDENCE, include_graph: false)
      normalized_format = format.to_sym
      raise Error, "Unknown report format: #{format}" unless FORMATS.include?(normalized_format)

      case normalized_format
      when :json
        report.to_json(include_graph: include_graph)
      when :sarif
        render_sarif(min_confidence)
      when :github, :annotations
        render_github_annotations(min_confidence)
      when :yaml, :yml
        report.to_yaml(include_graph: include_graph)
      when :human
        render_human(min_confidence)
      end
    end

    private

    attr_reader :report

    def render_human(min_confidence)
      findings = (report.dead_methods(min_confidence: min_confidence) + report.blocked_methods).uniq
      lines = [
        'Necropsy report',
        "Root: #{report.root}",
        "Nodes: #{report.summary['nodes']}, Edges: #{report.summary['edges']}, Entry points: #{report.summary['entry_points']}",
        "Incomplete source files: #{report.summary['incomplete_files']}",
        "Findings: #{findings.length}"
      ]
      append_dynamic_diagnostic(lines)
      append_definition_resolution_diagnostic(lines)
      append_source_diagnostic(lines)
      append_analysis_scope_diagnostic(lines)
      append_reference_barrier_diagnostic(lines)

      findings.group_by(&:classification).sort_by do |classification, _|
        classification.to_s
      end.each do |classification, group|
        lines << ''
        lines << "#{classification} (#{group.length})"
        group.sort_by do |finding|
          [finding.node.file, finding.node.line, finding.node.id, finding.node.definition_id]
        end.each do |finding|
          lines << "  [#{finding.confidence}] #{finding.node.symbol_id} [#{finding.node.definition_id}] " \
                   "#{finding.node.file}:#{finding.node.line}"
          append_finding_blockers(lines, finding)
        end
      end

      lines.join("\n")
    end

    def append_finding_blockers(lines, finding)
      finding.blockers.each do |blocker|
        metadata = blocker.metadata
        location = [metadata['file'] || metadata[:file], metadata['line'] || metadata[:line]].compact.join(':')
        caller = metadata['caller_id'] || metadata[:caller_id]
        message = metadata['message'] || metadata[:message] || blocker.message
        lines << "    blocker #{blocker.kind} at #{location} caller=#{caller}"
        lines << "      scope #{blocker.scope_kind}=#{blocker.scope_value.inspect} message=#{message}"
        lines << "      reason #{blocker.reason}"
        lines << "      match #{metadata['snippet']}" if metadata['snippet']
      end
    end

    def append_dynamic_diagnostic(lines)
      diagnostic = report.diagnostics['dynamic_evidence']
      return unless diagnostic

      attempted = diagnostic.fetch('attempted')
      matched = diagnostic.fetch('matched')
      partially_matched = diagnostic.fetch('partially_matched')
      unmatched = diagnostic.fetch('unmatched')
      samples = diagnostic.fetch('unmatched_samples').values.flatten
      lines << "Dynamic evidence (positive-only): nodes attempted=#{attempted['nodes']} matched=#{matched['nodes']} " \
               "partial=#{partially_matched['nodes']} unmatched=#{unmatched['nodes']}; " \
               "edges attempted=#{attempted['edges']} matched=#{matched['edges']} " \
               "partial=#{partially_matched['edges']} unmatched=#{unmatched['edges']}"
      lines << "Unmatched dynamic evidence: #{samples.join(', ')}" unless samples.empty?
      append_dynamic_resolution_samples(lines, diagnostic)
    end

    def append_dynamic_resolution_samples(lines, diagnostic)
      resolution_samples = diagnostic['resolution_samples'] || diagnostic[:resolution_samples]
      return unless resolution_samples.is_a?(Hash)

      samples = %w[nodes edge_endpoints].flat_map do |kind|
        Array(resolution_samples[kind] || resolution_samples[kind.to_sym])
      end.select { |sample| (sample['status'] || sample[:status]).to_s == 'ambiguous' }
      resolution = diagnostic['resolution'] || diagnostic[:resolution]
      count = dynamic_ambiguous_resolution_count(resolution, samples)
      return unless count.positive?

      lines << "Ambiguous runtime references: #{count}"
      rendered_count = [count, DEFINITION_RESOLUTION_SAMPLE_LIMIT].min
      samples.first(rendered_count).each do |sample|
        endpoint = sample['endpoint'] || sample[:endpoint]
        prefix = endpoint ? "#{endpoint} " : ''
        ids = Array(sample['definition_ids'] || sample[:definition_ids])
        lines << "  #{prefix}#{definition_resolution_identifier(sample)} -> #{ids.join(', ')}"
      end
      omitted = count - [samples.length, rendered_count].min
      lines << "  ... #{omitted} more" if omitted.positive?
    end

    def dynamic_ambiguous_resolution_count(resolution, samples)
      return samples.length unless resolution.is_a?(Hash)

      %w[nodes edge_endpoints].sum do |kind|
        counts = resolution[kind] || resolution[kind.to_sym]
        counts.is_a?(Hash) ? Integer(counts['ambiguous'] || counts[:ambiguous] || 0) : 0
      end
    rescue ArgumentError, TypeError
      samples.length
    end

    def append_source_diagnostic(lines)
      diagnostic = report.diagnostics['source_incompleteness']
      return unless diagnostic

      diagnostic.fetch('files').each do |file|
        errors = file.fetch('errors')
        if errors.empty?
          lines << "Incomplete source: #{file['file']}:1 [#{file['status']}]"
          next
        end

        errors.each do |error|
          lines << "Incomplete source: #{error['file']}:#{error['line']} [#{error['type']}] #{error['message']}"
        end
      end
    end

    def append_analysis_scope_diagnostic(lines)
      diagnostic = report.diagnostics['analysis_scope']
      return unless diagnostic

      reference_only = Array(diagnostic['reference_only_ruby_files'])
      excluded_callers = diagnostic['potential_callers_outside_reference'] || {}
      lines << "Analysis scope: analyzed Ruby=#{diagnostic.fetch('analyze_file_count')}, " \
               "reference files=#{diagnostic.fetch('reference_file_count')}, " \
               "reference-only Ruby=#{reference_only.length}"
      if excluded_callers.fetch('count', 0).positive?
        lines << "Potential callers outside reference: #{excluded_callers.fetch('count')} " \
                 "(runtime=#{excluded_callers.fetch('runtime_count', 0)}): " \
                 "#{Array(excluded_callers['samples']).join(', ')}"
      end
      Array(diagnostic['potential_entry_points_outside_analyze']).each do |entry|
        lines << "Potential entry point outside analysis: #{entry.fetch('file')} [#{entry.fetch('reference_status')}]"
      end
      Array(diagnostic['ignored_symlinks']).each do |file|
        lines << "Ignored symlink: #{file}"
      end
    end

    def append_reference_barrier_diagnostic(lines)
      diagnostic = report.diagnostics['non_ruby_reference_barrier']
      return unless diagnostic

      lines << "Non-Ruby reference barrier: scanned=#{diagnostic.fetch('files_scanned')}/" \
               "#{diagnostic.fetch('files_considered')}, matches=#{diagnostic.fetch('matches')}, " \
               "blocked definitions=#{diagnostic.fetch('matched_definitions')}"
      skipped = diagnostic.fetch('skipped_counts')
      lines << "Skipped non-Ruby references: #{skipped.map { |reason, count| "#{reason}=#{count}" }.join(', ')}" \
        unless skipped.empty?
    end

    def append_definition_resolution_diagnostic(lines)
      diagnostic = report.diagnostics['definition_resolution']
      return unless diagnostic

      entries = definition_resolution_entries(diagnostic)
      count = definition_resolution_count(diagnostic, entries)
      lines << "Ambiguous definition inputs: #{count}"
      rendered_count = [count, DEFINITION_RESOLUTION_SAMPLE_LIMIT].min
      entries.first(rendered_count).each do |entry|
        if entry.is_a?(Hash)
          kind = entry['kind'] || entry[:kind] || entry['status'] || entry[:status] || 'unknown'
          identifier = definition_resolution_identifier(entry)
          ids = Array(entry['definition_ids'] || entry[:definition_ids])
          lines << "  #{kind} #{identifier} -> #{ids.join(', ')}"
        else
          lines << "  #{entry}"
        end
      end
      omitted = count - [entries.length, rendered_count].min
      lines << "  ... #{omitted} more" if omitted.positive?
    end

    def definition_resolution_entries(diagnostic)
      return diagnostic if diagnostic.is_a?(Array)
      return [] unless diagnostic.is_a?(Hash)

      %w[ambiguous_inputs ambiguities samples].each do |key|
        value = diagnostic[key] || diagnostic[key.to_sym]
        return value if value.is_a?(Array)
      end
      []
    end

    def definition_resolution_identifier(entry)
      direct = entry['identifier'] || entry[:identifier]
      return direct if direct

      reference = entry['reference'] || entry[:reference]
      return reference unless reference.is_a?(Hash)

      identifier = reference['identifier'] || reference[:identifier] ||
                   reference['definition_id'] || reference[:definition_id] ||
                   reference['symbol_id'] || reference[:symbol_id] || 'unknown'
      file = reference['file'] || reference[:file]
      line = reference['line'] || reference[:line]
      location = [file, line].compact.join(':')
      location.empty? ? identifier : "#{identifier} @ #{location}"
    end

    def definition_resolution_count(diagnostic, entries)
      return entries.length unless diagnostic.is_a?(Hash)

      counts = diagnostic['counts'] || diagnostic[:counts]
      nested_count = counts['ambiguous'] || counts[:ambiguous] if counts.is_a?(Hash)
      value = diagnostic['ambiguous_input_count'] || diagnostic[:ambiguous_input_count] ||
              diagnostic['ambiguous_count'] || diagnostic[:ambiguous_count] ||
              diagnostic['count'] || diagnostic[:count] || nested_count
      Integer(value || entries.length)
    rescue ArgumentError, TypeError
      entries.length
    end

    def render_github_annotations(min_confidence)
      finding_annotations = report.dead_methods(min_confidence: min_confidence).map do |finding|
        message = "#{finding.classification} #{finding.node.symbol_id} definition_id=#{finding.node.definition_id} " \
                  "confidence=#{finding.confidence}"
        "::warning file=#{finding.node.file},line=#{finding.node.line},title=Necropsy #{finding.confidence}::" \
          "#{escape_annotation(message)}"
      end
      source_annotations = source_diagnostic_entries.map do |entry|
        message = "Incomplete source (#{entry['status']}, #{entry['type']}): #{entry['message']}"
        "::warning file=#{entry['file']},line=#{entry['line']},title=Necropsy incomplete source::" \
          "#{escape_annotation(message)}"
      end
      (finding_annotations + source_annotations).join("\n")
    end

    def render_sarif(min_confidence)
      findings = report.dead_methods(min_confidence: min_confidence)
      source_entries = source_diagnostic_entries
      {
        'version' => '2.1.0',
        '$schema' => 'https://json.schemastore.org/sarif-2.1.0.json',
        'runs' => [
          {
            'tool' => {
              'driver' => {
                'name' => 'Necropsy',
                'informationUri' => 'https://github.com/ydah/necropsy',
                'rules' => sarif_rules(findings, source_entries)
              }
            },
            'results' => findings.map { |finding| sarif_result(finding) } + source_entries.map { |entry| sarif_source_result(entry) }
          }
        ]
      }.to_json
    end

    def sarif_rules(findings, source_entries)
      rules = findings.map(&:classification).uniq.map do |classification|
        {
          'id' => classification.to_s,
          'name' => classification.to_s,
          'shortDescription' => { 'text' => "Necropsy #{classification}" }
        }
      end
      return rules if source_entries.empty?

      rules << {
        'id' => 'parse_incomplete',
        'name' => 'parse_incomplete',
        'shortDescription' => { 'text' => 'Necropsy incomplete source' }
      }
    end

    def sarif_result(finding)
      {
        'ruleId' => finding.classification.to_s,
        'level' => sarif_level(finding),
        'message' => { 'text' => "#{finding.node.id} is #{finding.classification} (#{finding.confidence})" },
        'properties' => {
          'symbolId' => finding.node.symbol_id,
          'definitionId' => finding.node.definition_id
        },
        'locations' => [
          {
            'physicalLocation' => {
              'artifactLocation' => { 'uri' => finding.node.file },
              'region' => { 'startLine' => finding.node.line }
            }
          }
        ],
        'partialFingerprints' => { 'necropsy' => finding.fingerprint }
      }
    end

    def sarif_level(finding)
      return 'error' if %i[certain high].include?(finding.confidence)
      return 'warning' if finding.confidence == :medium

      'note'
    end

    def sarif_source_result(entry)
      {
        'ruleId' => 'parse_incomplete',
        'level' => 'warning',
        'message' => {
          'text' => "Incomplete source (#{entry['status']}, #{entry['type']}): #{entry['message']}"
        },
        'locations' => [
          {
            'physicalLocation' => {
              'artifactLocation' => { 'uri' => entry['file'] },
              'region' => { 'startLine' => entry['line'] }
            }
          }
        ]
      }
    end

    def source_diagnostic_entries
      diagnostic = report.diagnostics['source_incompleteness']
      return [] unless diagnostic

      diagnostic.fetch('files').flat_map do |file|
        errors = file.fetch('errors')
        if errors.empty?
          next [{ 'file' => file['file'], 'line' => 1, 'type' => file['status'],
                  'message' => 'No source diagnostic was available', 'status' => file['status'] }]
        end

        errors.map { |error| error.merge('status' => file['status']) }
      end
    end

    def escape_annotation(message)
      message.gsub('%', '%25').gsub("\n", '%0A').gsub("\r", '%0D')
    end
  end
end
