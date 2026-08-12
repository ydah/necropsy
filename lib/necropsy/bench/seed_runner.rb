# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'yaml'

require_relative 'candidate_union'
require_relative 'precision_gate'
require_relative 'report_normalizer'

module Necropsy
  module Bench
    class SeedRunner
      def initialize(
        manifest_path:,
        output_dir:,
        io: $stdout,
        clock: Process.method(:clock_gettime),
        analyzer: nil,
        feature_ablation: {},
        rss_reader: nil,
        revision_reader: nil,
        dirty_reader: nil
      )
        @manifest_path = File.expand_path(manifest_path)
        @output_dir = File.expand_path(output_dir)
        @io = io
        @clock = clock
        @analyzer = analyzer || lambda { |root, config_path|
          Necropsy.analyze(root: root, config_path: config_path, profile: true)
        }
        @feature_ablation = feature_ablation
        @rss_reader = rss_reader || method(:read_process_rss)
        @revision_reader = revision_reader || method(:read_git_revision)
        @dirty_reader = dirty_reader || method(:tracked_git_dirty?)
      end

      def call(update_golden_reason: nil)
        prepare_output
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
        update_golden(update_golden_reason, corpus_runs) if update_golden_reason
        golden = golden_status
        report_golden_status(golden)
        summary = build_summary(corpus_runs, union, golden)
        write_json(File.join(output_dir, 'summary.json'), summary)
        summary
      end

      private

      attr_reader :manifest_path, :output_dir, :io, :clock, :analyzer, :feature_ablation, :rss_reader,
                  :revision_reader, :dirty_reader

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

      def prepare_output
        FileUtils.mkdir_p(reports_dir)
        Dir.glob(File.join(reports_dir, '*.json')).each { |path| FileUtils.rm_f(path) }
      end

      def run_corpus(id, definition, reports)
        path = corpus_path(definition)
        return skipped_corpus(id, definition, path) unless path && File.directory?(path)

        revision_error = pinned_corpus_error(definition, path)
        return failed_revision(id, definition, revision_error) if revision_error

        samples = performance_sample_count
        measurements = Array.new(samples) do
          started_at = monotonic_time
          report = analyzer.call(path, config_path(path, definition))
          wall_time = monotonic_time - started_at
          normalized = ReportNormalizer.new(report: report, corpus: id).call
          {
            report: report,
            normalized: normalized,
            wall_time: wall_time,
            rss: rss_measurement(id),
            allocated_objects: report.performance_profile&.dig('totals', 'allocated_objects'),
            artifact_size_bytes: JSON.generate(normalized).bytesize
          }
        end
        report = measurements.last.fetch(:report)
        normalized = measurements.last.fetch(:normalized)
        reports[id] = normalized
        write_json(File.join(reports_dir, "#{id}.json"), normalized)
        io.puts "#{id}: generated"
        performance = performance_distribution(measurements)
        analysis_profile = report.performance_profile if report.respond_to?(:performance_profile)
        performance['analysis_profile'] = analysis_profile if analysis_profile
        {
          'id' => id,
          'status' => 'generated',
          'revision' => definition['revision'],
          'metrics' => normalized.fetch('metrics'),
          'performance' => performance
        }.compact
      rescue Error, SystemCallError => e
        message = "#{id} failed: #{e.message}"
        diagnostics << message
        io.puts message
        { 'id' => id, 'status' => 'failed', 'diagnostic' => message }
      end

      def performance_sample_count
        value = Integer(manifest.fetch('performance_samples', 1))
        raise Error, 'performance_samples must be between 1 and 20' unless value.between?(1, 20)

        value
      rescue ArgumentError, TypeError
        raise Error, 'performance_samples must be between 1 and 20'
      end

      def performance_distribution(measurements)
        wall_times = measurements.map { |measurement| measurement.fetch(:wall_time) }
        allocations = measurements.filter_map { |measurement| measurement[:allocated_objects] }
        artifact_sizes = measurements.map { |measurement| measurement.fetch(:artifact_size_bytes) }
        rss = measurements.map { |measurement| measurement.fetch(:rss) }.max_by { |value| rss_value(value) || -1 }
        {
          'sample_count' => measurements.length,
          'wall_time_seconds' => mean(wall_times).round(6),
          'wall_time_p95_seconds' => percentile(wall_times, 0.95).round(6),
          'wall_time_max_seconds' => wall_times.max.round(6),
          'allocated_objects_p95' => percentile(allocations, 0.95),
          'allocated_objects_max' => allocations.max,
          'artifact_size_p95_bytes' => percentile(artifact_sizes, 0.95),
          'artifact_size_max_bytes' => artifact_sizes.max
        }.compact.merge(rss)
      end

      def percentile(values, quantile)
        return if values.empty?

        sorted = values.sort
        sorted.fetch([(sorted.length * quantile).ceil - 1, 0].max)
      end

      def mean(values)
        values.sum.to_f / values.length
      end

      def rss_value(measurement)
        measurement['process_hwm_kb'] || measurement['process_rss_kb']
      end

      def corpus_path(definition)
        env_path = ENV[definition['path_env'].to_s] if definition['path_env']
        relative = env_path || definition['path']
        File.expand_path(relative, repository_root) if relative && !relative.empty?
      end

      def config_path(path, definition)
        config = definition['config']
        return unless config

        repository_config = File.expand_path(config, repository_root)
        return repository_config if File.file?(repository_config)

        File.expand_path(config, path)
      end

      def skipped_corpus(id, definition, path)
        source = definition['path_env'] ? "set #{definition['path_env']}" : path.inspect
        message = "#{id} skipped: corpus unavailable (#{source})"
        diagnostics << message
        io.puts message
        { 'id' => id, 'status' => 'skipped', 'revision' => definition['revision'], 'diagnostic' => message }.compact
      end

      def pinned_corpus_error(definition, path)
        expected = definition['git_commit']
        return unless expected

        actual = revision_reader.call(path, 'HEAD')
        return "expected Git HEAD #{expected}, got #{actual || 'not a Git checkout'} at #{path}" unless actual == expected

        tag = definition['git_tag']
        tag_revision = revision_reader.call(path, "refs/tags/#{tag}^{commit}") if tag
        return "expected Git tag #{tag} at #{expected}, got #{tag_revision || 'missing'}" if tag && tag_revision != expected

        "tracked Git changes present at #{path}" if dirty_reader.call(path)
      end

      def failed_revision(id, definition, reason)
        message = "#{id} failed: #{reason}"
        diagnostics << message
        io.puts message
        { 'id' => id, 'status' => 'failed', 'revision' => definition['git_commit'], 'diagnostic' => message }
      end

      def rss_measurement(id)
        measurement = rss_reader.call
        return measurement if measurement

        message = "#{id}: RSS unavailable on this platform"
        diagnostics << message unless diagnostics.include?(message)
        { 'rss_status' => 'unavailable', 'rss_diagnostic' => message }
      end

      def read_process_rss
        status_path = '/proc/self/status'
        if File.file?(status_path)
          match = File.read(status_path).match(/^VmHWM:\s+(\d+)\s+kB$/)
          if match
            return {
              'process_hwm_kb' => match[1].to_i,
              'rss_kind' => 'cumulative_process_high_water_mark',
              'rss_scope' => 'benchmark_runner_process'
            }
          end
        end

        output = IO.popen(['ps', '-o', 'rss=', '-p', Process.pid.to_s], &:read)
        rss = Integer(output.strip, exception: false)
        return unless rss

        {
          'process_rss_kb' => rss,
          'rss_kind' => 'current_process_rss_after_corpus',
          'rss_scope' => 'benchmark_runner_process'
        }
      rescue ArgumentError, SystemCallError
        nil
      end

      def read_git_revision(path, reference)
        output, status = Open3.capture2e('git', '-C', path, 'rev-parse', reference)
        status.success? ? output.strip : nil
      rescue SystemCallError
        nil
      end

      def tracked_git_dirty?(path)
        output, status = Open3.capture2e('git', '-C', path, 'status', '--porcelain', '--untracked-files=no')
        !status.success? || !output.strip.empty?
      rescue SystemCallError
        true
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
          'feature_ablation' => deterministic_payload(feature_ablation),
          'precision_gate' => precision_gate(union),
          'golden' => golden,
          'diagnostics' => diagnostics.sort
        }
      end

      def precision_gate(union)
        policy = manifest['precision_gate']
        unless policy
          return {
            'schema_version' => 1,
            'enforced' => false,
            'compatibility' => 'manifest without precision_gate retains the benchmark-v1 policy',
            'passed' => true
          }
        end

        PrecisionGate.new(
          policy: policy,
          candidate_union_summary: union.fetch('summary'),
          feature_ablation: feature_ablation
        ).call
      end

      def deterministic_payload(value)
        case value
        when Hash
          value.sort.to_h { |key, nested| [key.to_s, deterministic_payload(nested)] }
        when Array
          value.map { |nested| deterministic_payload(nested) }
        else
          value
        end
      end

      def golden_status
        golden_dir = File.expand_path(manifest.fetch('golden_dir'), repository_root)
        return { 'status' => 'missing', 'differences' => deterministic_artifacts } unless File.directory?(golden_dir)

        integrity = golden_integrity(golden_dir)
        return integrity unless integrity['status'] == 'valid'

        expected = artifact_contents(golden_dir)
        actual = artifact_contents(output_dir)
        differences = (expected.keys | actual.keys).reject { |path| expected[path] == actual[path] }.sort
        { 'status' => differences.empty? ? 'match' : 'drift', 'differences' => differences }
      end

      def golden_integrity(golden_dir)
        metadata_path = File.join(golden_dir, 'metadata.json')
        return { 'status' => 'invalid', 'differences' => ['metadata.json missing'] } unless File.file?(metadata_path)

        metadata = JSON.parse(File.read(metadata_path))
        reason = metadata['update_reason'].to_s.strip
        return { 'status' => 'invalid', 'differences' => ['update reason missing'] } if reason.empty?

        actual = artifact_digests(golden_dir)
        expected = metadata.fetch('artifacts', {})
        differences = (actual.keys | expected.keys).reject { |path| actual[path] == expected[path] }.sort
        return { 'status' => 'invalid', 'differences' => differences } unless differences.empty?

        { 'status' => 'valid', 'differences' => [] }
      rescue JSON::ParserError
        { 'status' => 'invalid', 'differences' => ['metadata.json malformed'] }
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

      def artifact_digests(root)
        artifact_contents(root).transform_values { |contents| Digest::SHA256.hexdigest(contents) }
      end

      def report_golden_status(golden)
        differences = golden.fetch('differences')
        suffix = differences.empty? ? '' : " (#{differences.join(', ')})"
        io.puts "golden: #{golden.fetch('status')}#{suffix}"
      end

      def write_json(path, payload)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(payload)}\n")
      end

      def update_golden(reason, corpus_runs)
        raise Error, 'Updating benchmark golden files requires a non-empty reason' if reason.to_s.strip.empty?

        ensure_required_corpora_generated!(corpus_runs)

        golden_dir = File.expand_path(manifest.fetch('golden_dir'), repository_root)
        FileUtils.mkdir_p(File.join(golden_dir, 'reports'))
        FileUtils.cp(File.join(output_dir, 'candidate_union.json'), File.join(golden_dir, 'candidate_union.json'))
        sources = Dir.glob(File.join(output_dir, 'reports', '*.json'))
        sources.each do |source|
          FileUtils.cp(source, File.join(golden_dir, 'reports', File.basename(source)))
        end
        write_json(File.join(golden_dir, 'metadata.json'), {
                     'schema_version' => 1,
                     'update_reason' => reason.strip,
                     'artifacts' => artifact_digests(golden_dir).sort.to_h
                   })
      end

      def ensure_required_corpora_generated!(corpus_runs)
        statuses = corpus_runs.to_h { |corpus| [corpus.fetch('id'), corpus.fetch('status')] }
        missing = manifest.fetch('corpora').filter_map do |id, definition|
          id if definition['required'] == true && statuses[id] != 'generated'
        end.sort
        return if missing.empty?

        raise Error, "Cannot update golden files; required corpora were not generated: #{missing.join(', ')}"
      end
    end
  end
end
