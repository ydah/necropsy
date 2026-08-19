# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'CallGraph dependency boundary' do
  it 'loads the graph boundary without loading the complete public API' do
    lib = File.expand_path('../../../lib', __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      '-I',
      lib,
      '-e',
      'require "necropsy/graph/call_graph"'
    )

    expect(status).to be_success, stderr
  end
end
