# frozen_string_literal: true

require 'open3'

module Necropsy
  module Guardrail
    class Diff
      def self.changed_files(root:, diff_base:)
        stdout, stderr, status = Open3.capture3('git', '-C', root, 'diff', '--name-only', "#{diff_base}...HEAD")
        unless status.success?
          detail = stderr.strip.empty? ? 'unknown git error' : stderr.strip
          raise Error, "Could not determine changed files from #{diff_base}: #{detail}"
        end

        stdout.lines.map(&:strip).reject(&:empty?).to_set
      end
    end
  end
end
