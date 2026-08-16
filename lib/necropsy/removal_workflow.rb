# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

module Necropsy
  class RemovalWorkflow
    PROOF_OBLIGATIONS = %w[source load dispatch framework external_contract dynamic_evidence].freeze
    OUTPUT_LIMIT = 4_096

    def initialize(report_path:, candidate:, root:)
      @report = load_report(report_path)
      @candidate = find_candidate(candidate)
      @root = File.expand_path(root)
    end

    def plan
      {
        'schema_version' => 1,
        'candidate' => candidate_identity,
        'proof_obligations' => proof_obligations,
        'recommended_verification' => ['bundle exec rspec'],
        'policy' => 'preview_and_verify_in_isolated_copy'
      }
    end

    def patch_preview
      original, replacement, path = source_replacement
      return '' if original == replacement

      removed_count = original.length - replacement.length
      [
        "--- a/#{path}",
        "+++ b/#{path}",
        "@@ -#{candidate_line},#{removed_count} +#{candidate_line},0 @@",
        *original[candidate_line - 1, removed_count].map { |line| "-#{line}" }
      ].join
    end

    def verify(command)
      raise Error, 'verification command must not be empty' if command.empty?

      Dir.mktmpdir('necropsy-verify') do |directory|
        worktree = File.join(directory, File.basename(@root))
        FileUtils.cp_r(@root, worktree)
        apply_removal(worktree)
        stdout, stderr, status = Open3.capture3(*command, chdir: worktree)
        return {
          'candidate' => candidate_identity,
          'passed' => status.success?,
          'status' => status.exitstatus,
          'command' => command,
          'worktree' => 'temporary copy (removed after verification)',
          'stdout' => bounded(stdout),
          'stderr' => bounded(stderr)
        }
      end
    end

    private

    def candidate_identity
      node = @candidate.fetch('node', {})
      {
        'definition_id' => node['definition_id'],
        'symbol_id' => node['symbol_id'] || node['id'],
        'file' => node['file'],
        'line' => node['line'],
        'end_line' => node['end_line'],
        'classification' => @candidate['classification'],
        'actionability' => @candidate['actionability']
      }.compact
    end

    def proof_obligations
      health = @report.fetch('analysis_health', {})
      blockers = Array(@candidate['blockers'])
      statuses = {
        'source' => health.fetch('status', 'unknown') == 'complete' ? 'complete' : 'partial',
        'load' => @report.dig('diagnostics', 'unrooted_load_units') ? 'partial' : 'complete',
        'dispatch' => blockers.empty? ? 'complete' : 'partial',
        'framework' => blockers.empty? ? 'complete' : 'partial',
        'external_contract' => public_surface? ? 'review' : 'complete',
        'dynamic_evidence' => 'positive_only'
      }
      PROOF_OBLIGATIONS.to_h do |name|
        [name, { 'status' => statuses.fetch(name), 'required_action' => required_action(name, statuses.fetch(name)) }]
      end
    end

    def required_action(name, status)
      return 'no blocker recorded' if status == 'complete'
      return 'runtime observations are positive evidence only; review rare paths' if name == 'dynamic_evidence'

      "resolve or review #{name} evidence before removal"
    end

    def public_surface?
      %w[public protected].include?(@candidate.dig('node', 'visibility').to_s)
    end

    def source_replacement(root: @root)
      node = @candidate.fetch('node')
      path = safe_source_path(root, node.fetch('file'))
      lines = File.readlines(path)
      first = Integer(node.fetch('line'))
      last = Integer(node.fetch('end_line', first))
      raise Error, 'candidate source range is invalid' unless first.positive? && last >= first && last <= lines.length

      replacement = lines.dup
      replacement.slice!(first - 1, last - first + 1)
      [lines, replacement, node.fetch('file')]
    rescue KeyError, ArgumentError, SystemCallError => e
      raise Error, "Could not build removal patch: #{e.message}"
    end

    def apply_removal(worktree)
      _original, replacement, node_path = source_replacement(root: worktree)
      path = safe_source_path(worktree, node_path)
      File.write(path, replacement.join)
    end

    def safe_source_path(root, relative_path)
      path = File.expand_path(relative_path, root)
      root_prefix = "#{File.expand_path(root)}/"
      raise Error, "candidate path escapes project root: #{relative_path}" unless path.start_with?(root_prefix)
      raise Error, "candidate source does not exist: #{relative_path}" unless File.file?(path)

      path
    end

    def candidate_line
      Integer(@candidate.dig('node', 'line'))
    end

    def find_candidate(identifier)
      candidates = Array(@report['findings']).select do |finding|
        node = finding['node'] || {}
        [node['definition_id'], node['id'], node['symbol_id']].include?(identifier)
      end
      raise Error, "Candidate not found: #{identifier}" if candidates.empty?
      raise Error, "Candidate is ambiguous; use a physical definition ID: #{identifier}" if candidates.length > 1

      candidates.first
    end

    def load_report(path)
      contents = File.read(File.expand_path(path))
      JSON.parse(contents)
    rescue JSON::ParserError
      YAML.safe_load(contents, aliases: false) || {}
    rescue SystemCallError, Psych::Exception => e
      raise Error, "Could not read removal report #{path}: #{e.message}"
    end

    def bounded(value)
      value.to_s.byteslice(0, OUTPUT_LIMIT)
    end
  end
end
