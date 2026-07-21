# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Static::CHA do
  it 'expands instance dispatch across descendants and included modules' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    base = node('Base#render', owner: 'Base', name: 'render')
    child = node('Child#render', owner: 'Child', name: 'render')
    mod = node('Renderable#render', owner: 'Renderable', name: 'render')
    site = call_site(
      caller_id: caller.id,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Base',
      metadata: { 'receiver_candidates' => ['Base'] }
    )
    graph = graph_with(
      nodes: [caller, base, child, mod],
      call_sites: [site],
      class_infos: [
        class_info('Base'),
        class_info('Child', superclass: 'Base', includes: ['Renderable']),
        class_info('Renderable', kind: :module)
      ]
    )

    result = described_class.new.analyze(graph, nil)

    expect(result.edge_evidences.map(&:callee_id)).to contain_exactly('Base#render', 'Child#render',
                                                                      'Renderable#render')
  end

  it 'resolves singleton dispatch through class-level receivers' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    callee = node('Factory.build', kind: :singleton_method, owner: 'Factory', name: 'build')
    site = call_site(caller_id: caller.id, message: 'build', receiver_kind: :constant, receiver_name: 'Factory')
    graph = graph_with(nodes: [caller, callee], call_sites: [site], class_infos: [class_info('Factory')])

    expect(described_class.new.analyze(graph, nil).edge_evidences.map(&:callee_id)).to eq(['Factory.build'])
  end

  it 'resolves module instance methods exposed through extend' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    extended = node('Messages#deliver', owner: 'Messages', name: 'deliver')
    site = call_site(caller_id: caller.id, message: 'deliver', receiver_kind: :constant, receiver_name: 'Notifier')
    graph = graph_with(
      nodes: [caller, extended],
      call_sites: [site],
      class_infos: [class_info('Notifier', extends: ['Messages']), class_info('Messages', kind: :module)]
    )

    expect(described_class.new.analyze(graph, nil).edge_evidences.map(&:callee_id)).to eq(['Messages#deliver'])
  end
end
