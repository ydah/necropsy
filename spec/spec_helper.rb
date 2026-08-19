# frozen_string_literal: true

require 'necropsy'
require 'tmpdir'

# Command-specific files are loaded explicitly in production. The shared spec
# helper loads them for unit tests that exercise those public classes directly.
%w[
  artifact_loader
  feedback_workflow
  reporter
  doctor
  diagnostics
  guardrail/baseline
  guardrail/diff
  guardrail/quarantine
  removal_workflow
  bench/finding_facts
  bench/evaluator
  bench/claim_gate
  bench/review_queue
].each { |path| require "necropsy/#{path}" }

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |path| require path }

def fixture_path(path)
  File.expand_path(File.join('fixtures', path), __dir__)
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  config.define_derived_metadata do |metadata|
    metadata[:aggregate_failures] = true
  end

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
