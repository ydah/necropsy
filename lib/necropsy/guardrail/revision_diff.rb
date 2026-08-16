# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'rubygems/package'
require 'stringio'
require 'tmpdir'

module Necropsy
  module Guardrail
    class RevisionDiff
      def self.compare(root:, base_revision:, head_revision: nil, config_path: nil)
        new(root: root, base_revision: base_revision, head_revision: head_revision, config_path: config_path).compare
      end

      def initialize(root:, base_revision:, head_revision:, config_path:)
        @root = File.realpath(root)
        @base_revision = base_revision.to_s
        @head_revision = head_revision&.to_s
        @config_path = config_path
        raise Error, 'base revision must not be empty' if @base_revision.empty?
        raise Error, 'head revision must not be empty' if @head_revision == ''
      rescue Errno::ENOENT => e
        raise Error, "Git repository root does not exist: #{e.message}"
      end

      def compare
        Dir.mktmpdir('necropsy-revision-diff') do |directory|
          base_root = materialize_revision(directory, 'base', @base_revision)
          base_report = analyze_revision(base_root)
          head_report = if @head_revision
                          analyze_revision(materialize_revision(directory, 'head', @head_revision))
                        else
                          analyze_current_worktree
                        end

          Diff.new(base: normalize_root(base_report), head: normalize_root(head_report)).compare
        end
      end

      private

      def analyze_revision(root)
        Necropsy.analyze(root: root, config_path: revision_config_path(root)).to_h(include_graph: true)
      end

      def analyze_current_worktree
        Necropsy.analyze(root: @root, config_path: @config_path).to_h(include_graph: true)
      end

      def revision_config_path(_root)
        return unless @config_path
        return @config_path unless Pathname.new(@config_path).absolute?

        relative = Pathname.new(@config_path).relative_path_from(Pathname.new(@root)).to_s
        raise Error, 'absolute config path must be inside the Git repository root' if relative.start_with?('../')

        relative
      rescue ArgumentError => e
        raise Error, "Could not resolve revision config path: #{e.message}"
      end

      def normalize_root(report)
        report.merge('root' => @root)
      end

      def materialize_revision(directory, label, revision)
        destination = File.join(directory, label)
        FileUtils.mkdir_p(destination)
        extract_archive(archive_revision(revision), destination)
        destination
      end

      def archive_revision(revision)
        resolved_revision = resolve_revision(revision)
        stdout, stderr, status = Open3.capture3('git', '-C', @root, 'archive', '--format=tar', resolved_revision)
        return stdout if status.success?

        detail = stderr.strip.empty? ? 'unknown git error' : stderr.strip
        raise Error, "Could not materialize Git revision #{revision}: #{detail}"
      end

      def resolve_revision(revision)
        stdout, stderr, status = Open3.capture3(
          'git', '-C', @root, 'rev-parse', '--verify', '--end-of-options', "#{revision}^{commit}"
        )
        resolved = stdout.strip
        return resolved if status.success? && resolved.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)

        detail = stderr.strip.empty? ? 'not a commit revision' : stderr.strip
        raise Error, "Could not resolve Git revision #{revision}: #{detail}"
      end

      def extract_archive(archive, destination)
        Gem::Package::TarReader.new(StringIO.new(archive)).each do |entry|
          relative = entry.full_name.to_s.sub(%r{\A\./}, '')
          path = safe_archive_path(destination, relative)
          if entry.directory?
            FileUtils.mkdir_p(path)
          elsif entry.symlink?
            raise Error, "Git revision contains unsupported symlink: #{relative}"
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(path))
            File.open(path, 'wb') { |file| IO.copy_stream(entry, file) }
            File.chmod(entry.header.mode & 0o7777, path)
          end
        end
      rescue Gem::Package::TarInvalidError, IOError => e
        raise Error, "Could not extract Git revision: #{e.message}"
      end

      def safe_archive_path(destination, relative)
        path = File.expand_path(relative, destination)
        prefix = "#{File.expand_path(destination)}/"
        raise Error, "Git revision archive path escapes its root: #{relative}" unless path.start_with?(prefix)

        path
      end
    end
  end
end
