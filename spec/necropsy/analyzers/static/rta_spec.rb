# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Static::RTA do
  subject(:analyzer) { described_class.new }

  describe '#profile' do
    it 'describes RTA output as rank-only evidence' do
      expect(analyzer.profile.description).to eq(
        'Marks constructed-class dispatch candidates as ranking and diagnostic evidence.'
      )
    end
  end

  describe '#analyze' do
    subject(:result) { analyzer.analyze(graph, nil) }

    let(:caller) { node('Caller#run', owner: 'Caller', name: 'run') }
    let(:live) { node('Live#render', owner: 'Live', name: 'render') }
    let(:dead) { node('Dead#render', owner: 'Dead', name: 'render') }
    let(:site) { call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown) }
    let(:graph) { graph_with(nodes: [caller, live, dead], call_sites: [site], instantiated_classes: Set['Live']) }

    it 'filters instance call targets to instantiated classes' do
      expect(result.edge_evidences.map(&:callee_id)).to eq(['Live#render'])
      expect(result.edge_evidences.first.evidence.metadata.fetch('instantiated_classes')).to eq(['Live'])
    end
  end

  describe '#implicit_sites' do
    subject(:implicit_sites) { analyzer.implicit_sites(site) }

    let(:site) { call_site(caller_id: 'Caller#run', message: 'map', receiver_kind: :unknown) }

    it 'adds protocol calls for common Ruby methods' do
      expect(implicit_sites.map(&:message)).to include('each')
      expect(implicit_sites.first.metadata).to include('implicit_from' => 'map')
    end
  end

  describe '#implicit_messages' do
    it 'adds comparison and string conversion protocols' do
      expect(analyzer.implicit_messages('sort')).to include('<=>', 'each')
      expect(analyzer.implicit_messages('puts')).to eq(['to_s'])
    end
  end

  it 'keeps reachability monotonic as roots, edges, and allocations are added' do
    reachable = lambda do |instantiated_classes: Set.new, extra_root: false, extra_edge: false|
      caller = node('Caller#run', owner: 'Caller', name: 'run')
      other_root = node('Other#run', owner: 'Other', name: 'run')
      target = node('Live#render', owner: 'Live', name: 'render')
      extra = node('Extra#work', owner: 'Extra', name: 'work')
      site = call_site(caller_id: caller.id, message: 'render', receiver_kind: :unknown)
      graph = graph_with(
        nodes: [caller, other_root, target, extra],
        call_sites: [site],
        instantiated_classes: instantiated_classes
      )
      graph.add_entry_point(caller.id, :main_script)
      graph.add_entry_point(other_root.id, :main_script) if extra_root
      graph.add_edge(caller.id, extra.id, evidence) if extra_edge
      graph.apply_result(analyzer.analyze(graph, nil))
      Necropsy::Reachability::Engine.new(graph).call.runtime_alive.to_set
    end

    baseline = reachable.call

    expect(baseline - reachable.call(extra_root: true)).to be_empty
    expect(baseline - reachable.call(extra_edge: true)).to be_empty
    expect(baseline - reachable.call(instantiated_classes: Set['Live'])).to be_empty
  end
end
