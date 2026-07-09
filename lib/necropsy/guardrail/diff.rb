# frozen_string_literal: true

require 'open3'

module Necropsy
  module Guardrail
    class Diff
      def self.changed_files(root:, diff_base:)
        stdout, status = Open3.capture2('git', '-C', root, 'diff', '--name-only', "#{diff_base}...HEAD")
        return Set.new unless status.success?

        stdout.lines.map(&:strip).reject(&:empty?).to_set
      end
    end
  end
end
