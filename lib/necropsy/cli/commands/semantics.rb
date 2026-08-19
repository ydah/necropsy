# frozen_string_literal: true

require_relative '../../semantics_matrix'

module Necropsy
  class CLI
    module Commands
      class Semantics
        def call(options:, arguments:)
          raise Error, "Unexpected semantics arguments: #{arguments.join(' ')}" unless arguments.empty?

          puts SemanticsMatrix.new.render(format: options[:format])
          0
        end
      end
    end
  end
end
