# frozen_string_literal: true

require 'rbconfig'

RSpec.describe 'necropsy/trace_point_runtime' do
  it 'installs the TracePoint collector in an external Ruby process' do
    with_project(files: {
      'runner.rb' => <<~RUBY
        class TracePointRuntimeSample
          def run
            :ok
          end
        end

        TracePointRuntimeSample.new.run
      RUBY
    }) do |root|
      output = File.join(root, 'trace.yml')
      env = {
        'NECROPSY_TRACE_ROOT' => root,
        'NECROPSY_TRACE_OUTPUT' => output,
        'NECROPSY_TRACE_MERGE' => '1',
        'NECROPSY_TRACE_RUN_ID' => 'runtime-spec',
        'RUBYLIB' => File.expand_path('../../lib', __dir__)
      }

      expect(system(env, RbConfig.ruby, '-rnecropsy/trace_point_runtime', File.join(root, 'runner.rb'))).to eq(true)
      payload = YAML.load_file(output)

      expect(payload.fetch('nodes')).to include('TracePointRuntimeSample#run')
      expect(payload.fetch('observation')).to include('run_id' => 'runtime-spec')
    end
  end
end
