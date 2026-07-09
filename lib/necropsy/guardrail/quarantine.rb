# frozen_string_literal: true

require 'date'

module Necropsy
  module Guardrail
    class Quarantine
      ANNOTATION_PREFIX = '# necropsy:quarantine'

      def initialize(report:, root:)
        @report = report
        @root = root
      end

      def suggestions(min_confidence: :high)
        report.dead_methods(min_confidence: min_confidence).map do |finding|
          {
            finding: finding,
            annotation: "#{ANNOTATION_PREFIX} since=#{Date.today.iso8601}",
            path: File.join(root, finding.node.file),
            line: finding.node.line
          }
        end
      end

      def write(min_confidence: :high)
        grouped = suggestions(min_confidence: min_confidence).group_by { |suggestion| suggestion[:path] }
        grouped.each do |path, entries|
          lines = File.readlines(path, chomp: true)
          entries.sort_by { |entry| -entry[:line] }.each do |entry|
            index = [entry[:line] - 1, 0].max
            next if lines[index - 1]&.include?(ANNOTATION_PREFIX)

            indent = lines[index][/^\s*/] || ''
            lines.insert(index, "#{indent}#{entry[:annotation]}")
          end
          File.write(path, "#{lines.join("\n")}\n")
        end
      end

      private

      attr_reader :report, :root
    end
  end
end
