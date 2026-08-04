# frozen_string_literal: true

require 'digest'
require 'yaml'

module Necropsy
  module Bench
    class CandidateUnion
      LABELS = %w[dead alive external unknown].freeze

      def initialize(manifest:, repository_root:, reports:, diagnostics:)
        @manifest = manifest
        @repository_root = repository_root
        @reports = reports
        @diagnostics = diagnostics
      end

      def call
        load_necropsy_candidates
        load_external_candidates
        apply_labels
        fill_tool_results
        result = {
          'schema_version' => 1,
          'tool_runs' => tool_runs.sort.to_h,
          'summary' => summary,
          'candidates' => candidates.values.sort_by { |candidate| [candidate['corpus'], candidate['id']] }
        }
        validate_result!(result)
        result
      end

      private

      attr_reader :manifest, :repository_root, :reports, :diagnostics

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
            candidate = candidate_for(corpus, finding.fetch('id'), finding)
            candidate['tool_results']['necropsy'] = {
              'candidate' => true,
              'state' => finding.fetch('state'),
              'confidence' => finding.fetch('confidence')
            }
          end
        end
      end

      def load_external_candidates
        manifest.fetch('tools', {}).sort.each do |tool, definition|
          next if tool == 'necropsy'

          path = snapshot_path(definition)
          unless path && File.file?(path)
            skip_tool(tool, definition)
            next
          end

          payload = YAML.safe_load_file(path, aliases: false) || {}
          validate_snapshot!(payload, tool)
          Array(payload['candidates']).each do |entry|
            candidate = candidate_for(entry.fetch('corpus'), entry.fetch('id'), entry)
            candidate['tool_results'][tool] = {
              'candidate' => true,
              'classification' => entry['classification'] || 'candidate'
            }
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
        raise Error, 'schema_version must be 1' unless payload['schema_version'] == 1
        raise Error, "tool must be #{tool}" unless payload['tool'] == tool

        provenance = payload['provenance']
        raise Error, 'provenance must be a non-empty mapping' unless provenance.is_a?(Hash) && !provenance.empty?
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
        candidates[key] ||= {
          'corpus' => corpus,
          'id' => id,
          'path' => source['path'],
          'line' => source['line'],
          'tool_results' => {}
        }.compact
      end

      def apply_labels
        path = File.expand_path(manifest.fetch('labels'), repository_root)
        payload = YAML.safe_load_file(path, aliases: false) || {}
        labels = Array(payload['labels'])
        minimum = Integer(manifest.fetch('minimum_reviewed_labels', 30))
        raise Error, "Benchmark seed requires at least #{minimum} reviewed labels" if labels.length < minimum

        labels.each do |entry|
          validate_label(entry)
          key = [entry.fetch('corpus'), entry.fetch('id')]
          candidate = candidates[key]
          raise Error, "Benchmark label does not match a tool candidate: #{key.join(':')}" unless candidate
          raise Error, "Duplicate benchmark label: #{key.join(':')}" if candidate.key?('label')

          candidate['label'] = entry.slice('value', 'rationale', 'reviewer')
        end
      rescue KeyError, ArgumentError, Psych::Exception => e
        raise Error, "Invalid benchmark labels: #{e.message}"
      end

      def validate_label(entry)
        value = entry.fetch('value')
        raise Error, "Invalid benchmark label #{value.inspect}" unless LABELS.include?(value)
        raise Error, "Benchmark label #{entry['id']} requires a rationale" if entry['rationale'].to_s.strip.empty?
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
          'by_label' => labels.tally.sort.to_h
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
