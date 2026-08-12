# frozen_string_literal: true

RSpec.describe Necropsy::GraphSelfCheck do
  it 'accepts a fully analyzed graph and its derived protocol sites' do
    source = <<~RUBY
      class Item
        def <=>(other) = 0
      end
      class Client
        def run = [Item.new].sort
      end
    RUBY

    with_project(files: { 'app/sample.rb' => source }, config: { cache: { enabled: false } }) do |root|
      report = Necropsy::Runner.new(root: root).analyze

      expect(described_class.new(report).call).to eq([])
      expect(described_class.new(report).validate!).to be(true)
    end
  end

  it 'rejects a derived call site without a resolution record' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    derived = call_site(
      caller_id: caller.graph_id,
      message: 'to_s',
      metadata: { 'derived_from_call_site_id' => 'call:v1:parent' }
    )
    graph = graph_with(nodes: [caller], call_sites: [derived])
    report = report_with_findings([], graph: graph)

    expect(described_class.new(report).call).to include(
      'code' => 'derived_call_site_has_no_resolution', 'subject' => derived.call_site_id
    )
    expect { described_class.new(report).validate! }.to raise_error(
      Necropsy::GraphSelfCheck::Failure, /derived_call_site_has_no_resolution/
    )
  end
end
