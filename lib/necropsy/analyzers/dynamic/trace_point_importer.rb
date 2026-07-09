# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Dynamic
      class TracePointImporter < CoverageImporter
        def profile
          AnalyzerProfile.new(
            name: :trace_point,
            kind: :dynamic,
            soundness: :observational,
            description: 'Imports method execution and caller-callee edges captured by Necropsy TracePoint recording.'
          )
        end
      end
    end
  end
end
