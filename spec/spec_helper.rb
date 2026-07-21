# frozen_string_literal: true

require 'necropsy'
require 'tmpdir'

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
