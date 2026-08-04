# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'yaml'

require_relative 'candidate_union'
require_relative 'report_normalizer'

module Necropsy
  module Bench
    class SeedRunner
      DETERMINISTIC_FILES = %w[candidate_union.json reports].freeze

      def initialize(manifest_path:, output_dir:, io: $stdout, clock: Process.method(:clock_gettime), analyzer: nil)
        @manifest_path = File.expand_path(manifest_path)
        @output_dir = File.expand_path(output_dir)
        @io = io
        @clock = clock
        @analyzer = analyzer || ->(root, config_path) { Necropsy.analyze(root: root, config_path: config_path) }
      end

      def call(update_golden_reason: nil)
        FileUtils.mkdir_p(reports_dir)
        reports = {}
        corpus_runs = manifest.fetch('corpora').sort.map do |id, definition|
          run_corpus(id, definition, reports)
        end
        union = CandidateUnion.new(
          manifest: manifest,
          repository_root: repository_root,
          reports: reports,
          diagnostics: diagnostics
        ).call
        write_json(File.join(output_dir, 'candidate_union.json'), union)
        summary = build_summary(corpus_runs, union, golden_status)
        write_json(File.join(output_dir, 'summary.json'), summary)
        update_golden(update_golden_reason) if update_golden_reason
        summary
      end

      private

      attr_reader :manifest_path, :output_dir, :io, :clock, :analyzer

      def manifest
        @manifest ||= YAML.safe_load_file(manifest_path, aliases: false).tap do |payload|
          raise Error, 'Benchmark manifest schema_version must be 1' unless payload&.fetch('schema_version', nil) == 1
        end
      rescue Psych::Exception => e
        raise Error, "Could not parse benchmark manifest: #{e.message}"
      end

      def repository_root
        @repository_root ||= File.expand_path(manifest.fetch('repository_root'), File.dirname(manifest_path))
      end

      def reports_dir
        File.join(output_dir, 'reports')
      end

      def diagnostics
        @diagnostics ||= []
      end

      def run_corpus(id, definition, reports)
        path = corpus_path(definition)
        return skipped_corpus(id, definition, path) unless path && File.directory?(path)

        started_at = monotonic_time
        report = analyzer.call(path, config_path(path, definition))
        wall_time = monotonic_time - started_at
        normalized = ReportNormalizer.new(report: report, corpus: id).call
        reports[id] = normalized
        write_json(File.join(reports_dir, "#{id}.json"), normalized)
        io.puts "#{id}: generated"
        {
          'id' => id,
          'status' => 'generated',
          'revision' => definition['revision'],
          'metrics' => normalized.fetch('metrics'),
          'performance' => {
            'wall_time_seconds' => wall_time.round(6),
            'peak_rss_kb' => current_rss_kb,
            'rss_measurement' => 'process high-water mark when available; current RSS fallback'
          }
        }.compact
      rescue Error, SystemCallError => e
        message = "#{id} failed: #{e.message}"
        diagnostics << message
        io.puts message
        { 'id' => id, 'status' => 'failed', 'diagnostic' => message }
      end

      def corpus_path(definition)
        env_path = ENV[definition['path_env'].to_s] if definition['path_env']
        relative = env_path || definition['path']
        File.expand_path(relative, repository_root) if relative && !relative.empty?
      end

      def config_path(path, definition)
        config = definition['config']
        File.expand_path(config, path) if config
      end

      def skipped_corpus(id, definition, path)
        source = definition['path_env'] ? "set #{definition['path_env']}" : path.inspect
        message = "#{id} skipped: corpus unavailable (#{source})"
        diagnostics << message
        io.puts message
        { 'id' => id, 'status' => 'skipped', 'revision' => definition['revision'], 'diagnostic' => message }.compact
      end

      def current_rss_kb
        status_path = '/proc/self/status'
        if File.file?(status_path)
          match = File.read(status_path).match(/^VmHWM:\s+(\d+)\s+kB$/)
          return match[1].to_i if match
        end

        output = IO.popen(['ps', '-o', 'rss=', '-p', Process.pid.to_s], &:read)
        Integer(output.strip, exception: false)
      rescue ArgumentError, SystemCallError
        nil
      end

      def monotonic_time
        clock.call(Process::CLOCK_MONOTONIC)
      end

      def build_summary(corpus_runs, union, golden)
        {
          'schema_version' => 1,
          'manifest' => File.basename(manifest_path),
          'corpora' => corpus_runs,
          'candidate_union' => union.fetch('summary'),
          'golden' => golden,
          'diagnostics' => diagnostics.sort
        }
      end

      def golden_status
        golden_dir = File.expand_path(manifest.fetch('golden_dir'), repository_root)
        return { 'status' => 'missing', 'differences' => deterministic_artifacts } unless File.directory?(golden_dir)

        expected = artifact_contents(golden_dir)
        actual = artifact_contents(output_dir)
        differences = (expected.keys | actual.keys).reject { |path| expected[path] == actual[path] }.sort
        { 'status' => differences.empty? ? 'match' : 'drift', 'differences' => differences }
      end

      def deterministic_artifacts
        ['candidate_union.json'] + Dir.glob(File.join(output_dir, 'reports', '*.json')).map do |path|
          File.join('reports', File.basename(path))
        end.sort
      end

      def artifact_contents(root)
        paths = ['candidate_union.json'] + Dir.glob(File.join(root, 'reports', '*.json')).map do |path|
          File.join('reports', File.basename(path))
        end.sort
        paths.to_h do |relative|
          path = File.join(root, relative)
          [relative, File.file?(path) ? File.binread(path) : nil]
        end
      end

      def write_json(path, payload)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(payload)}\n")
      end

      def update_golden(reason)
        raise Error, 'Updating benchmark golden files requires a non-empty reason' if reason.to_s.strip.empty?

        golden_dir = File.expand_path(manifest.fetch('golden_dir'), repository_root)
        FileUtils.mkdir_p(File.join(golden_dir, 'reports'))
        FileUtils.cp(File.join(output_dir, 'candidate_union.json'), File.join(golden_dir, 'candidate_union.json'))
        Dir.glob(File.join(output_dir, 'reports', '*.json')).each do |source|
          FileUtils.cp(source, File.join(golden_dir, 'reports', File.basename(source)))
        end
        File.write(File.join(golden_dir, 'UPDATE_REASON.txt'), "#{reason.strip}\n")
      end
    end
  end
end
