# frozen_string_literal: true

module Necropsy
  module Reporters
    module Support
      private

      attr_reader :report

      def source_diagnostic_entries
        diagnostic = report.diagnostics['source_incompleteness']
        return [] unless diagnostic

        diagnostic.fetch('files').flat_map do |file|
          errors = file.fetch('errors')
          if errors.empty?
            next [{ 'file' => file['file'], 'line' => 1, 'type' => file['status'],
                    'message' => 'No source diagnostic was available', 'status' => file['status'] }]
          end

          errors.map { |error| error.merge('status' => file['status']) }
        end
      end

      def positive_line(value)
        line = Integer(value)
        line if line.positive?
      rescue ArgumentError, TypeError
        nil
      end

      def health_annotations
        report.analysis_health.reasons.map do |reason|
          level = reason.fetch('severity') == 'invalid' ? 'error' : 'warning'
          title = "Necropsy analysis #{report.analysis_health.status}"
          message = "#{reason.fetch('code')}: #{reason['message']}"
          location = if reason['file']
                       " file=#{reason['file']},line=#{positive_line(reason['line']) || 1},"
                     else
                       ' '
                     end
          "::#{level}#{location}title=#{title}::#{escape_annotation(message)}"
        end
      end

      def escape_annotation(message)
        message.gsub('%', '%25').gsub("\n", '%0A').gsub("\r", '%0D')
      end
    end
  end
end
