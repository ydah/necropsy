# frozen_string_literal: true

require 'necropsy/analyzers/dynamic/coverage_collector'

root = ENV.fetch('NECROPSY_COVERAGE_ROOT', nil)
output = ENV.fetch('NECROPSY_COVERAGE_OUTPUT', nil)
merge = ENV['NECROPSY_COVERAGE_MERGE'] == '1'
run_id = ENV.fetch('NECROPSY_COVERAGE_RUN_ID', nil)

if root && output
  Necropsy::Analyzers::Dynamic::CoverageCollector.install_at_exit(root: root, output: output, merge: merge,
                                                                  run_id: run_id)
end
