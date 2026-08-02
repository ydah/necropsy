# frozen_string_literal: true

require 'pathname'

module Necropsy
  class Project
    EXCLUDED_DIRECTORIES = %w[
      .bundle
      .git
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
      @scan_result ||= Cache::ScanCache.new(project: self).fetch(ruby_files) do
        AstScanner.new(project: self, files: ruby_files).scan
      end
    end

    def ruby_files
      @ruby_files ||= begin
        globbed = Dir.glob(File.join(root, '**', '*.rb'))
        special = %w[Rakefile].map { |name| File.join(root, name) }.select { |file| File.file?(file) }
        rake = Dir.glob(File.join(root, '**', '*.rake'))
        executables = Dir.glob(File.join(root, '{bin,exe}', '*')).select { |file| File.file?(file) }
        gemspecs = Dir.glob(File.join(root, '*.gemspec'))
        candidates = (globbed + special + rake + executables + gemspecs).uniq
        candidates.select! { |file| analyzable_file?(file) }
        warn_excluded_entry_points(candidates) if config.include_paths.any?
        candidates.select! { |file| included_path?(relative_path(file)) } if config.include_paths.any?
        candidates.reject! { |file| excluded_path?(relative_path(file)) }
        candidates.sort
      end
    end

    def test_file?(file)
      relative = relative_path(file)
      relative.start_with?('spec/', 'test/')
    end

    def relative_path(file)
      Pathname.new(File.expand_path(file)).relative_path_from(Pathname.new(root)).to_s
    end

    def changed_files(diff_base)
      Guardrail::Diff.changed_files(root: root, diff_base: diff_base)
    end

    private

    def analyzable_file?(file)
      relative_parts = relative_path(file).split(File::SEPARATOR)
      return false if EXCLUDED_DIRECTORIES.include?(relative_parts.first)

      ruby_source?(file)
    rescue ArgumentError
      false
    end

    def ruby_source?(file)
      return true if file.end_with?('.rb', '.rake', '.gemspec') || File.basename(file) == 'Rakefile'

      File.open(file, &:readline).match?(/\A#!.*\bruby\b/)
    rescue EOFError, SystemCallError, EncodingError
      false
    end

    def included_path?(relative)
      config.include_paths.any? { |pattern| path_matches?(pattern, relative) }
    end

    def excluded_path?(relative)
      config.exclude_paths.any? { |pattern| path_matches?(pattern, relative) }
    end

    def path_matches?(pattern, relative)
      File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
        File.fnmatch?(File.join(pattern, '**', '*'), relative, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end

    def warn_excluded_entry_points(candidates)
      excluded = candidates.filter_map do |file|
        relative = relative_path(file)
        relative if potential_entry_point_path?(relative) && !included_path?(relative)
      end
      return if excluded.empty?

      sample = excluded.sort.first(5)
      suffix = excluded.length > sample.length ? " and #{excluded.length - sample.length} more" : ''
      warn "Necropsy paths.include excludes potential entry points: #{sample.join(', ')}#{suffix}. " \
           'Use report.include to filter findings without narrowing analysis.'
    end

    def potential_entry_point_path?(relative)
      relative == 'Rakefile' || relative == 'config/routes.rb' ||
        relative.start_with?('bin/', 'exe/', 'spec/', 'test/') ||
        relative.end_with?('.rake', '.gemspec')
    end
  end
end
