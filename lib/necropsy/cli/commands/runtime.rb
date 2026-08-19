# frozen_string_literal: true

module Necropsy
  class CLI
    module Commands
      class Record
        def initialize(runtime_evidence:)
          @runtime_evidence = runtime_evidence
        end

        def call(options:, arguments:)
          @runtime_evidence.record(options, arguments)
        end
      end

      class Coverage
        def initialize(runtime_evidence:)
          @runtime_evidence = runtime_evidence
        end

        def call(options:, arguments:)
          @runtime_evidence.coverage(options, arguments)
        end
      end
    end
  end
end
