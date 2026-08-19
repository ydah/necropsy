# frozen_string_literal: true

require 'pathname'
require 'digest'
require 'find'

module Necropsy
  class Project
    SOURCE_SNAPSHOT_MAX_BYTES = 268_435_456
    SOURCE_SNAPSHOT_MAX_FILES = 100_000
    SOURCE_DIGEST_CHUNK_BYTES = 65_536
    EXCLUDED_DIRECTORIES = %w[
      .bundle
      .git
      .necropsy_cache
      .ruby-lsp
      coverage
      doc
      node_modules
      pkg
      tmp
      vendor
    ].freeze

    attr_reader :root, :config

    def initialize(root:, config:)
      @root = File.expand_path(root)
      @config = config
    end

    def scan_result
      @scan_result ||= Cache::ScanCache.new(project: self).fetch(cache_files) do
        AstScanner.new(
          project: self,
          files: scan_files,
          source_domains: source_domains,
          scope_diagnostics: scope_diagnostics
        ).scan
      end
    end

    def ruby_files
      @ruby_files ||= begin
        candidates = if config.analyze_paths.any?
                       ruby_candidates.dup
                     else
                       default_analyze_candidates.dup
                     end
        warn_excluded_entry_points(candidates) if config.analyze_paths.any? || config.exclude_paths.any?
        candidates.select! { |file| analyzed_path?(relative_path(file)) } if config.analyze_paths.any?
        candidates.reject! { |file| excluded_path?(relative_path(file)) }
        candidates.sort
      end
    end

    def reference_files
      @reference_files ||= repository_files.select do |file|
        config.reference_paths.any? { |pattern| path_matches?(pattern, relative_path(file)) }
      end.sort
    end

    def reference_ruby_files
      @reference_ruby_files ||= reference_files.select { |file| ruby_source?(file) }
    end

    def non_ruby_reference_files
      @non_ruby_reference_files ||= (reference_files.to_set - reference_ruby_files.to_set).to_a.sort
    end

    def reference_file?(file)
      reference_file_set.include?(File.expand_path(file, root))
    rescue ArgumentError
      false
    end

    def frameworks
      @frameworks ||= config.frameworks(
        detected_frameworks: FrameworkDetector.new(root: root).detect(reference_files)
      )
    end

    def rails_enabled?
      frameworks.include?('rails')
    end

    def scan_files
      @scan_files ||= (ruby_files + reference_ruby_files).uniq
    end

    def cache_files
      @cache_files ||= (scan_files + reference_files).uniq
    end

    def scan_inventory_key
      {
        'ignored_symlinks' => ignored_symlinks.sort,
        'source_discovery_issues' => source_discovery_issues,
        'ruby_files_outside_scopes' => ruby_files_outside_scopes.map { |file| relative_path(file) }
      }
    end

    def source_snapshot
      @source_snapshot ||= build_source_snapshot
    end

    def fresh_source_snapshot
      self.class.new(root: root, config: config).source_snapshot
    end

    def source_domains
      @source_domains ||= begin
        analyzed = ruby_files.to_set
        scan_files.to_h do |file|
          [relative_path(file), analyzed.include?(file) ? :analyze : :reference]
        end
      end
    end

    def scope_diagnostics
      @scope_diagnostics ||= begin
        analyzed = ruby_files.to_set
        references = reference_ruby_files.to_set
        reference_only = (references - analyzed).map { |file| relative_path(file) }.sort
        excluded_callers = ruby_files_outside_scopes.map { |file| relative_path(file) }
        runtime_excluded_callers = excluded_callers.reject { |file| test_source_path?(file) }
        potential = ruby_candidates.filter_map do |file|
          next if analyzed.include?(file)
          next unless potential_entry_point_path?(relative_path(file))

          {
            'file' => relative_path(file),
            'reference_status' => references.include?(file) ? 'reference_only' : 'excluded'
          }
        end.sort_by { |entry| entry.fetch('file') }
        {
          'analyze_file_count' => ruby_files.length,
          'reference_file_count' => reference_files.length,
          'reference_only_ruby_files' => reference_only,
          'potential_callers_outside_reference' => {
            'count' => excluded_callers.length,
            'runtime_count' => runtime_excluded_callers.length,
            'samples' => excluded_callers.first(20)
          },
          'potential_entry_points_outside_analyze' => potential,
          'ignored_symlinks' => ignored_symlinks.sort,
          'source_discovery_issues' => source_discovery_issues
        }.tap { warn_excluded_callers(runtime_excluded_callers) }
      end
    end

    def scope_blockers
      excluded = scope_diagnostics.fetch('potential_callers_outside_reference')
      blockers = []
      if excluded.fetch('runtime_count').positive?
        blockers << Blocker.new(
          kind: :reference_scope_incomplete,
          scope_kind: :global,
          scope_value: '*',
          source: :source_discovery,
          reason: "paths.reference excludes #{excluded.fetch('runtime_count')} non-test Ruby caller candidates",
          suggested_action: :expand_reference_scope,
          metadata: {
            'caller_domain' => 'runtime',
            'excluded_file_count' => excluded.fetch('count'),
            'excluded_runtime_file_count' => excluded.fetch('runtime_count'),
            'files' => excluded.fetch('samples')
          }
        )
      end

      runtime_issues = source_discovery_issues.reject { |issue| issue.fetch('domain') == 'test' }
      if runtime_issues.any?
        blockers << Blocker.new(
          kind: :source_discovery_incomplete,
          scope_kind: :global,
          scope_value: '*',
          source: :source_discovery,
          reason: "#{runtime_issues.length} runtime source paths could not be inspected safely",
          suggested_action: :review_source_discovery,
          metadata: {
            'caller_domain' => 'runtime',
            'issue_count' => runtime_issues.length,
            'files' => runtime_issues.first(50)
          }
        )
      end
      blockers
    end

    def test_file?(file)
      test_source_path?(relative_path(file))
    end

    def relative_path(file)
      Pathname.new(File.expand_path(file)).relative_path_from(Pathname.new(root)).to_s
    end

    def changed_files(diff_base)
      require_relative 'guardrail/diff'

      Guardrail::Diff.changed_files(root: root, diff_base: diff_base)
    end

    private

    def build_source_snapshot
      files = cache_files.sort_by { |file| relative_path(file) }
      return unavailable_source_snapshot('file_limit', files: files.length) if files.length > SOURCE_SNAPSHOT_MAX_FILES

      total_bytes = files.sum { |file| File.size(file) }
      return unavailable_source_snapshot('byte_limit', files: files.length, bytes: total_bytes) if total_bytes > SOURCE_SNAPSHOT_MAX_BYTES

      digest = Digest::SHA256.new
      files.each { |file| digest_source_file(digest, file) }
      { 'status' => 'complete', 'sha256' => digest.hexdigest, 'files' => files.length, 'bytes' => total_bytes }
    rescue SystemCallError, IOError, ArgumentError => e
      unavailable_source_snapshot('read_error', error: e.class.name)
    end

    def digest_source_file(digest, file)
      relative = relative_path(file).b
      expected_bytes = File.size(file)
      digest << [relative.bytesize].pack('Q>') << relative << [expected_bytes].pack('Q>')
      actual_bytes = 0
      File.open(file, 'rb') do |io|
        while (chunk = io.read(SOURCE_DIGEST_CHUNK_BYTES))
          actual_bytes += chunk.bytesize
          digest << chunk
        end
      end
      raise IOError, "source changed while reading #{relative}" unless actual_bytes == expected_bytes
    end

    def unavailable_source_snapshot(reason, details = {})
      { 'status' => 'unavailable', 'sha256' => 'unavailable', 'reason' => reason }.merge(details)
    end

    def test_source_path?(relative)
      config.test_paths.any? { |pattern| path_matches?(pattern, relative) }
    end

    def repository_files
      @repository_files ||= begin
        @ignored_symlinks = Set.new
        @source_discovery_issues = []
        files = []
        begin
          Find.find(root) do |file|
            next if file == root

            if excluded_repository_path?(file)
              Find.prune if File.directory?(file) && !File.symlink?(file)
              next
            end
            next if cache_output_path?(file)

            if symlink_path?(file) || !real_path_within_root?(file)
              if File.symlink?(file) || File.file?(file)
                relative = relative_path(file)
                @ignored_symlinks << relative
                record_source_discovery_issue(relative, :symlink)
              end
              next
            end

            files << file if File.file?(file)
          rescue ArgumentError, SystemCallError => e
            record_source_discovery_issue(safe_relative_path(file), :inspection_error, error: e.class.name)
          end
        rescue ArgumentError, SystemCallError => e
          record_source_discovery_issue('.', :enumeration_error, error: e.class.name)
        end
        files.sort
      end
    end

    def ruby_candidates
      @ruby_candidates ||= repository_files.select { |file| ruby_source?(file) }
    end

    def reference_file_set
      @reference_file_set ||= reference_files.to_set
    end

    def ruby_files_outside_scopes
      @ruby_files_outside_scopes ||= (ruby_candidates.to_set - scan_files.to_set).to_a.sort
    end

    def default_analyze_candidates
      @default_analyze_candidates ||= ruby_candidates.select do |file|
        relative = relative_path(file)
        next false if relative.split(File::SEPARATOR).any? { |part| part.start_with?('.') }

        relative.end_with?('.rb', '.rake') || relative == 'Rakefile' ||
          relative.match?(%r{\A(?:bin|exe)/[^/]+\z}) || relative.match?(%r{\A[^/]+\.gemspec\z})
      end
    end

    def ignored_symlinks
      repository_files unless defined?(@ignored_symlinks)
      @ignored_symlinks
    end

    def source_discovery_issues
      repository_files unless defined?(@source_discovery_issues)
      @source_discovery_issues.sort_by { |issue| [issue.fetch('file'), issue.fetch('reason')] }
    end

    def record_source_discovery_issue(file, reason, error: nil)
      @source_discovery_issues ||= []
      issue = {
        'file' => file,
        'reason' => reason.to_s,
        'domain' => test_source_path?(file) ? 'test' : 'runtime'
      }
      issue['error'] = error if error
      @source_discovery_issues << issue unless @source_discovery_issues.include?(issue)
    end

    def safe_relative_path(file)
      relative_path(file)
    rescue ArgumentError, SystemCallError
      file.to_s
    end

    def excluded_repository_path?(file)
      relative_parts = relative_path(file).split(File::SEPARATOR)
      EXCLUDED_DIRECTORIES.include?(relative_parts.first) ||
        relative_parts.drop(1).intersect?(EXCLUDED_DIRECTORIES)
    rescue ArgumentError
      true
    end

    def cache_output_path?(file)
      File.expand_path(file) == File.expand_path(config.cache_path, root)
    rescue ArgumentError
      false
    end

    def symlink_path?(file)
      current = file
      until current == root
        return true if File.symlink?(current)

        parent = File.dirname(current)
        return true if parent == current

        current = parent
      end
      false
    end

    def real_path_within_root?(file)
      real_root = @real_root ||= File.realpath(root)
      real_file = File.realpath(file)
      real_file == real_root || real_file.start_with?("#{real_root}#{File::SEPARATOR}")
    end

    def ruby_source?(file)
      return true if file.end_with?('.rb', '.rake', '.gemspec') || File.basename(file) == 'Rakefile'

      File.binread(file, 256)&.match?(/\A\#![^\r\n]*\bruby\b/n) == true
    rescue SystemCallError => e
      record_source_discovery_issue(safe_relative_path(file), :read_error, error: e.class.name)
      false
    end

    def analyzed_path?(relative)
      config.analyze_paths.any? { |pattern| path_matches?(pattern, relative) }
    end

    def excluded_path?(relative)
      config.exclude_paths.any? { |pattern| path_matches?(pattern, relative) }
    end

    def path_matches?(pattern, relative)
      flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
      File.fnmatch?(pattern, relative, flags) || File.fnmatch?(File.join(pattern, '**', '*'), relative, flags)
    end

    def warn_excluded_entry_points(candidates)
      excluded = candidates.filter_map do |file|
        relative = relative_path(file)
        relative if potential_entry_point_path?(relative) && !ruby_files_include_candidate?(relative)
      end
      return if excluded.empty?

      sample = excluded.sort.first(5)
      suffix = excluded.length > sample.length ? " and #{excluded.length - sample.length} more" : ''
      scope = excluded_scope_label
      warn "Necropsy #{scope} excludes potential entry points: #{sample.join(', ')}#{suffix}. " \
           'Use report.include to filter findings without narrowing analysis.'
    end

    def warn_excluded_callers(files)
      return if files.empty?

      sample = files.first(5)
      suffix = files.length > sample.length ? " and #{files.length - sample.length} more" : ''
      warn 'Necropsy paths.reference excludes Ruby files that may contain runtime callers: ' \
           "#{sample.join(', ')}#{suffix}. Findings are blocked until the reference scope is expanded."
    end

    def excluded_scope_label
      return 'paths.include' if config.legacy_include_paths?
      return 'paths.analyze/paths.exclude' if config.analyze_paths.any? && config.exclude_paths.any?
      return 'paths.exclude' if config.exclude_paths.any?

      'paths.analyze'
    end

    def ruby_files_include_candidate?(relative)
      included = config.analyze_paths.none? || analyzed_path?(relative)
      included && !excluded_path?(relative)
    end

    def potential_entry_point_path?(relative)
      relative == 'Rakefile' || relative == 'config/routes.rb' ||
        relative.start_with?('bin/', 'exe/') || test_source_path?(relative) ||
        relative.end_with?('.rake', '.gemspec')
    end
  end
end
