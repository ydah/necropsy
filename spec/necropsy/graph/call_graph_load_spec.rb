# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'CallGraph dependency boundary' do
  def load_graph_component(component)
    lib = File.expand_path('../../../lib', __dir__)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      '-I',
      lib,
      '-e',
      "require \"necropsy/graph/#{component}\""
    )

    expect(status).to be_success, stderr
  end

  it 'loads the graph boundary without loading the complete public API' do
    load_graph_component('call_graph')
  end

  %w[evidence_ledger resolution_ledger].each do |component|
    it "loads #{component} without relying on CallGraph load order" do
      load_graph_component(component)
    end
  end
end
