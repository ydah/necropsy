# frozen_string_literal: true

require 'necropsy'

root = ENV.fetch('NECROPSY_TRACE_ROOT', nil)
output = ENV.fetch('NECROPSY_TRACE_OUTPUT', nil)
sample_rate = ENV.fetch('NECROPSY_TRACE_SAMPLE_RATE', '1.0').to_f
merge = ENV['NECROPSY_TRACE_MERGE'] == '1'
run_id = ENV.fetch('NECROPSY_TRACE_RUN_ID', nil)

if root && output
  Necropsy::Analyzers::Dynamic::TracePointCollector.install_at_exit(
    root: root,
    output: output,
    sample_rate: sample_rate,
    merge: merge,
    run_id: run_id
  )
end
