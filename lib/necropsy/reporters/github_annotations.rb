# frozen_string_literal: true

require_relative 'support'

module Necropsy
  module Reporters
    class GithubAnnotations
      include Support

      def initialize(report)
        @report = report
      end

      def render(min_confidence)
        finding_annotations = report.dead_methods(min_confidence: min_confidence).map do |finding|
          message = "#{finding.classification} #{finding.node.symbol_id} definition_id=#{finding.node.definition_id} " \
                    "confidence=#{finding.confidence}"
          "::warning file=#{finding.node.file},line=#{finding.node.line},title=Necropsy #{finding.confidence}::" \
            "#{escape_annotation(message)}"
        end
        source_annotations = source_diagnostic_entries.map do |entry|
          message = "Incomplete source (#{entry['status']}, #{entry['type']}): #{entry['message']}"
          "::warning file=#{entry['file']},line=#{entry['line']},title=Necropsy incomplete source::" \
            "#{escape_annotation(message)}"
        end
        (finding_annotations + source_annotations + health_annotations).join("\n")
      end
    end
  end
end
