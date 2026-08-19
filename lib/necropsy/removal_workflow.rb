# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'timeout'
require_relative 'artifact_loader'

module Necropsy
  class RemovalWorkflow
    PROOF_OBLIGATIONS = %w[source load dispatch framework external_contract dynamic_evidence].freeze
    OUTPUT_LIMIT = 4_096
    DEFAULT_TIMEOUT_SECONDS = 300

    def initialize(report_path:, candidate:, root:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
      @report = ArtifactLoader.load_mapping(report_path, label: 'Removal report')
      validate_report!
      @candidate = find_candidate(candidate)
      @root = File.expand_path(root)
      @timeout_seconds = normalize_timeout(timeout_seconds)
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
        stdout, stderr, status, timed_out = run_command(command, worktree)
        return {
          'candidate' => candidate_identity,
          'passed' => !timed_out && status&.success?,
          'status' => status&.exitstatus,
          'timed_out' => timed_out,
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
      lines = read_source_lines(path)
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
      File.open(path, File::WRONLY | File::TRUNC | File::NOFOLLOW) do |file|
        file.write(replacement.join)
      end
    rescue Errno::ELOOP => e
      raise Error, "candidate source became a symlink during removal: #{e.message}"
    end

    def safe_source_path(root, relative_path)
      root = File.realpath(root)
      path = File.expand_path(relative_path, root)
      root_prefix = "#{root}/"
      raise Error, "candidate path escapes project root: #{relative_path}" unless path.start_with?(root_prefix)

      reject_symlink_components(root, path, relative_path)
      raise Error, "candidate source does not exist: #{relative_path}" unless File.file?(path)

      path
    rescue Errno::ENOENT => e
      raise Error, "candidate source does not exist: #{relative_path}: #{e.message}"
    end

    def reject_symlink_components(root, path, relative_path)
      relative = path.delete_prefix("#{root}/")
      current = root
      relative.split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        raise Error, "candidate path contains a symlink: #{relative_path}" if File.symlink?(current)
      end
    end

    def read_source_lines(path)
      File.open(path, File::RDONLY | File::NOFOLLOW, &:readlines)
    rescue Errno::ELOOP => e
      raise Error, "candidate source is a symlink: #{e.message}"
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

    def validate_report!
      findings = @report['findings']
      raise Error, 'Removal report must contain findings' unless findings.is_a?(Array)
      raise Error, 'Removal report findings must contain mappings' unless findings.all?(Hash)
      raise Error, 'Removal report finding nodes must contain mappings' unless
        findings.all? { |finding| !finding.key?('node') || finding['node'].is_a?(Hash) }
    end

    def normalize_timeout(value)
      seconds = Float(value)
      raise Error, 'verification timeout must be positive and finite' unless seconds.positive? && seconds.finite?

      seconds
    rescue ArgumentError, TypeError
      raise Error, 'verification timeout must be positive and finite'
    end

    def run_command(command, worktree)
      stdout_chunks = []
      stderr_chunks = []
      timed_out = false
      status = nil

      Open3.popen3(*command, chdir: worktree, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [stdout, stderr].zip([stdout_chunks, stderr_chunks]).map do |io, chunks|
          Thread.new { read_output(io, chunks) }
        end
        begin
          status = Timeout.timeout(@timeout_seconds) { wait_thread.value }
        rescue Timeout::Error
          timed_out = true
          terminate_process(wait_thread.pid)
          status = begin
            wait_thread.value
          rescue StandardError
            nil
          end
        ensure
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
          readers.each(&:join)
        end
      end

      [stdout_chunks.join, stderr_chunks.join, status, timed_out]
    end

    def read_output(io, chunks)
      stored = 0
      loop do
        part = io.read(1_024)
        break unless part

        remaining = OUTPUT_LIMIT - stored
        if remaining.positive?
          chunks << part.byteslice(0, remaining)
          stored += [part.bytesize, remaining].min
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def terminate_process(pid)
      Process.kill('TERM', -pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
      nil
    end

    def bounded(value)
      value.to_s.byteslice(0, OUTPUT_LIMIT)
    end
  end
end
