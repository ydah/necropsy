# frozen_string_literal: true

RSpec.describe Necropsy::Graph::RubyDispatch do
  it 'owns concrete Ruby lookup while CallGraph remains the facade' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Service#call', owner: 'Service', name: 'call')
    site = call_site(
      caller_id: caller.id,
      message: 'call',
      receiver_kind: :instance,
      receiver_name: 'Service',
      metadata: { 'receiver_candidates' => ['Service'] }
    )
    graph = graph_with(nodes: [caller, target], call_sites: [site], class_infos: [class_info('Service')])
    dispatch = described_class.new(graph)

    expect(dispatch.method_lookup(site).targets).to eq([target])
    expect(graph.method_lookup(site)).to eq(dispatch.method_lookup(site))
    expect(graph.instance_variable_get(:@dispatch)).to be_a(described_class)
    expect(graph.instance_variable_get(:@dispatch)).not_to equal(dispatch)
  end
end
