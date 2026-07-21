# frozen_string_literal: true

require 'rbconfig'

RSpec.describe 'necropsy/coverage_runtime' do
  it 'installs the Coverage collector from environment variables in child Ruby processes' do
    with_project(files: {
                   'runner.rb' => <<~RUBY
                     class CoverageRuntimeSample
                       def run
                         :ok
                       end
                     end

                     CoverageRuntimeSample.new.run
                   RUBY
                 }) do |root|
      output = File.join(root, 'coverage.yml')
      env = {
        'NECROPSY_COVERAGE_ROOT' => root,
        'NECROPSY_COVERAGE_OUTPUT' => output,
        'NECROPSY_COVERAGE_MERGE' => '1',
        'NECROPSY_COVERAGE_RUN_ID' => 'runtime-spec',
        'RUBYLIB' => File.expand_path('../../lib', __dir__)
      }

      expect(system(env, RbConfig.ruby, '-rnecropsy/coverage_runtime', File.join(root, 'runner.rb'))).to eq(true)
      payload = YAML.load_file(output)

      expect(payload.fetch('nodes')).to include('CoverageRuntimeSample#run')
      expect(payload.fetch('observation')).to include('run_id' => 'runtime-spec')
    end
  end
end
