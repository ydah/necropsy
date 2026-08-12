# frozen_string_literal: true

require 'date'
require 'digest'
require 'tempfile'

module Necropsy
  module Guardrail
    class Quarantine
      ANNOTATION_PREFIX = '# necropsy:quarantine'

      def initialize(report:, root:, clock: Clock.new)
        @report = report
        @root = root
        @clock = clock
      end

      def suggestions(min_confidence: :high)
        findings = report.dead_methods(min_confidence: min_confidence)
        grouped = findings.group_by { |finding| [finding.node.file, finding.node.line] }
        source_digests = {}
        grouped.sort_by { |(file, line), _entries| [file, line] }.map do |(file, line), entries|
          entries = entries.sort_by { |finding| finding.node.definition_id }
          fingerprints = entries.map(&:physical_fingerprint).uniq
          path = source_path(file)
          source_digests[path] ||= Digest::SHA256.file(path).hexdigest
          {
            finding: entries.first,
            findings: entries.freeze,
            annotation: "#{ANNOTATION_PREFIX} since=#{clock.date.iso8601} #{fingerprint_field(fingerprints)}",
            fingerprints: fingerprints.freeze,
            source_sha256: source_digests.fetch(path),
            path: path,
            line: line
          }
        end
      end

      def write(min_confidence: :high)
        grouped = suggestions(min_confidence: min_confidence).group_by { |suggestion| suggestion[:path] }
        grouped.each do |path, entries|
          source = File.binread(path)
          verify_source_digest!(path, source, entries)
          newline = source[/\r\n|\n/] || "\n"
          trailing_newline = source.end_with?("\r\n", "\n")
          lines = source.split(/\r\n|\n/, -1)
          lines.pop if trailing_newline
          entries.sort_by { |entry| -entry[:line] }.each do |entry|
            index = [entry[:line] - 1, 0].max
            if index.positive? && lines[index - 1]&.include?(ANNOTATION_PREFIX)
              upgrade_existing_annotation!(lines, index - 1, entry)
              next
            end

            indent = lines[index][/^\s*/] || ''
            lines.insert(index, "#{indent}#{entry[:annotation]}")
          end
          rewritten = lines.join(newline)
          rewritten << newline if trailing_newline
          atomic_replace(path, rewritten, expected_sha256: entries.first.fetch(:source_sha256))
        end
      end

      private

      attr_reader :report, :root, :clock

      def source_path(relative)
        expanded_root = File.expand_path(root)
        path = File.expand_path(relative, expanded_root)
        real_root = File.realpath(expanded_root)
        real_path = File.realpath(path)
        inside_root = real_path.start_with?("#{real_root}#{File::SEPARATOR}")
        return path if path.start_with?("#{expanded_root}#{File::SEPARATOR}") && inside_root && File.file?(path)

        raise Error, "Quarantine source is outside the project or missing: #{relative}"
      rescue SystemCallError
        raise Error, "Quarantine source is outside the project or missing: #{relative}"
      end

      def fingerprint_field(fingerprints)
        return "fingerprint=#{fingerprints.first}" if fingerprints.one?

        "fingerprints=#{fingerprints.join(',')}"
      end

      def verify_source_digest!(path, source, entries)
        expected = entries.map { |entry| entry.fetch(:source_sha256) }.uniq
        current = Digest::SHA256.hexdigest(source)
        return if expected.one? && expected.first == current

        raise Error, "Quarantine source changed after analysis: #{path}"
      end

      def upgrade_existing_annotation!(lines, annotation_index, entry)
        annotation = lines.fetch(annotation_index)
        expected = entry.fetch(:fingerprints)
        return if annotation_fingerprints(annotation) == expected.sort

        raise Error, "Existing quarantine fingerprint does not match #{entry[:path]}:#{entry[:line]}" if
          annotation.match?(/\bfingerprints?=/)

        lines[annotation_index] = "#{annotation} #{fingerprint_field(expected)}"
      end

      def annotation_fingerprints(annotation)
        single = annotation[/\bfingerprint=([0-9a-f]{64})(?:\s|$)/, 1]
        multiple = annotation[/\bfingerprints=([0-9a-f]{64}(?:,[0-9a-f]{64})*)(?:\s|$)/, 1]
        Array(single || multiple&.split(',')).sort
      end

      def atomic_replace(path, contents, expected_sha256:)
        directory = File.dirname(path)
        mode = File.stat(path).mode & 0o7777
        Tempfile.create([".#{File.basename(path)}", '.tmp'], directory) do |file|
          file.binmode
          file.write(contents)
          file.flush
          file.fsync
          file.chmod(mode)
          file.close
          current = Digest::SHA256.file(path).hexdigest
          raise Error, "Quarantine source changed while writing: #{path}" unless current == expected_sha256

          File.rename(file.path, path)
        end
        fsync_directory(directory)
      end

      def fsync_directory(directory)
        File.open(directory, 'rb', &:fsync)
      rescue Errno::EINVAL, Errno::EISDIR
        nil
      end
    end
  end
end
