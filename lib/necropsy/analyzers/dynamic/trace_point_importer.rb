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
            description: 'Imports method execution and caller-callee edges captured by Necropsy TracePoint recording.',
            version: Necropsy::VERSION,
            assumptions: %w[positive_observations_only tracepoint_call_events]
          )
        end
      end
    end
  end
end
