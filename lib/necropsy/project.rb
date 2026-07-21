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
  end
end
