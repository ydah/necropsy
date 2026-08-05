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
    it 'adds comparison and string conversion protocols' do
      expect(analyzer.implicit_messages('sort')).to include('<=>', 'each')
      expect(analyzer.implicit_messages('puts')).to eq(['to_s'])
    end
  end
end
