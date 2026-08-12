# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Static::RTA do
  subject(:analyzer) { described_class.new }

  describe '#profile' do
    it 'describes RTA output as rank-only evidence' do
      expect(analyzer.profile.description).to eq(
        'RTA pruning mode rank_only records constructed-class hints without removing static edges.'
      )
    end

    it 'identifies legacy pruning in its diagnostic profile' do
      legacy = described_class.new(pruning: :legacy)

      expect(legacy.profile.description).to include('mode legacy', 'removes static candidates')
      expect(legacy.analyze(graph_with(nodes: []), nil).observation.dig('rta', 'pruning')).to eq('legacy')
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
      emitted = result.edge_evidences.first.evidence
      expect(emitted.metadata.fetch('instantiated_classes')).to eq(['Live'])
      expect(emitted).to have_attributes(
        grade: :heuristic,
        producer: :rta,
        producer_version: Necropsy::VERSION,
        relation: :call_edge
      )
      expect(result.evidences).to eq([emitted])
      expect(result.resolutions.first.resolution).to have_attributes(
        call_site_id: site.call_site_id,
        target_definition_ids: [live.graph_id],
        status: :partial,
        evidence_ids: [emitted.evidence_id]
      )
      expect(analyzer.profile).to have_attributes(
        version: Necropsy::VERSION,
        assumptions: %w[pruning=rank_only scanned_allocations]
      )
    end

    it 'registers receiver-transformed protocol sites and their resolutions' do
      protocol_target = node('Live#to_s', owner: 'Live', name: 'to_s')
      wrong_receiver_target = node('Caller#to_s', owner: 'Caller', name: 'to_s')
      protocol_site = call_site(
        caller_id: caller.graph_id,
        message: 'puts',
        receiver_kind: :implicit,
        metadata: {
          'argument_value_facts' => [{ 'kind' => 'instance_types', 'values' => ['Live'], 'exact' => true }]
        }
      )
      protocol_graph = graph_with(
        nodes: [caller, protocol_target, wrong_receiver_target],
        call_sites: [protocol_site],
        instantiated_classes: Set['Live'],
        class_infos: [class_info('Live')]
      )

      protocol_result = analyzer.analyze(protocol_graph, nil)
      protocol_graph.apply_result(protocol_result)

      derived_site = protocol_result.derived_call_sites.fetch(0)
      expect(derived_site).to have_attributes(message: 'to_s', receiver_kind: :instance, receiver_name: 'Live')
      expect(protocol_result.resolutions.map { |record| record.resolution.call_site_id }).to contain_exactly(
        protocol_site.call_site_id, derived_site.call_site_id
      )
      derived = protocol_result.edge_evidences.find { |edge| edge.callee_id == protocol_target.graph_id }
      expect(protocol_result.edge_evidences.map(&:callee_id)).not_to include(wrong_receiver_target.graph_id)
      expect(derived.evidence.metadata.fetch('metadata')).to include(
        'derived_from_call_site_id' => protocol_site.call_site_id,
        'derived_via' => 'rta_implicit',
        'protocol_receiver' => 'first_argument'
      )
      expect(protocol_graph.call_sites).to include(derived_site)
      expect(protocol_graph.resolution_records(derived_site.call_site_id)).not_to be_empty
      expect(protocol_graph.resolution_issues).to eq([])
    end

    it 'can retain resolution targets without duplicating existing static edges' do
      graph.add_edge(caller.graph_id, live.graph_id, evidence(analyzer: :cha, metadata: site.to_h))

      result = analyzer.without_redundant_edges.analyze(graph, nil)

      expect(result.edge_evidences).to be_empty
      expect(result.resolutions.first.resolution.target_definition_ids).to eq([live.graph_id])
    end
  end

  describe '#implicit_sites' do
    subject(:implicit_sites) { analyzer.implicit_sites(site) }

    let(:site) do
      call_site(
        caller_id: 'Caller#run', message: 'map', receiver_kind: :instance, receiver_name: 'Array',
        metadata: { 'receiver_candidates' => ['Array'] }
      )
    end

    it 'adds protocol calls for common Ruby methods' do
      expect(implicit_sites.map(&:message)).to include('each')
      expect(implicit_sites.first.metadata).to include('implicit_from' => 'map')
    end

    it 'derives stable identities from the source call site' do
      implicit = implicit_sites.fetch(0)

      expect(implicit.call_site_id).to eq(
        Necropsy::CallSiteIdentity.derived_id(
          parent_call_site_id: site.call_site_id,
          derivation: :rta_implicit,
          caller_definition_id: site.caller_id,
          message: implicit.message
        )
      )
      expect(implicit.call_site_id).not_to eq(site.call_site_id)
      expect(implicit.metadata).to include(
        'derived_from_call_site_id' => site.call_site_id,
        'derived_via' => 'rta_implicit'
      )
    end
  end

  describe '#implicit_messages' do
    it 'transforms comparison and string conversion receivers' do
      sort = call_site(
        caller_id: 'Caller#run', message: 'sort', receiver_kind: :instance, receiver_name: 'Array',
        metadata: { 'receiver_candidates' => ['Array'] }
      )
      output = call_site(
        caller_id: 'Caller#run', message: 'puts', receiver_kind: :implicit,
        metadata: {
          'argument_value_facts' => [{ 'kind' => 'instance_types', 'values' => ['Value'], 'exact' => true }]
        }
      )

      expect(analyzer.implicit_messages(sort)).to contain_exactly('<=>', 'each')
      converted = analyzer.implicit_sites(output).fetch(0)
      expect(converted).to have_attributes(message: 'to_s', receiver_name: 'Value')
      expect(converted.metadata).to include('protocol_receiver' => 'first_argument')
    end

    it 'does not derive Enumerable protocols from arbitrary user method names' do
      user_call = call_site(caller_id: 'Caller#run', message: 'map', receiver_kind: :instance, receiver_name: 'Live')

      expect(analyzer.implicit_sites(user_call)).to be_empty
    end
  end
end
