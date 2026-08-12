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

    it 'does not iterate for blockless Enumerable calls that return an Enumerator' do
      blockless = call_site(
        caller_id: 'Caller#run', message: 'map', receiver_kind: :instance, receiver_name: 'Array',
        metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => 'none' }
      )

      expect(analyzer.implicit_sites(blockless)).to be_empty
    end

    it 'uses literal array element facts for comparison protocol receivers' do
      sort = call_site(
        caller_id: 'Caller#run', message: 'sort', receiver_kind: :instance, receiver_name: 'Array',
        metadata: {
          'receiver_candidates' => ['Array'],
          'block_kind' => 'none',
          'receiver_value_fact' => {
            'kind' => 'container',
            'exact' => true,
            'summary' => {
              'type' => 'array',
              'element_fact' => { 'kind' => 'instance_types', 'values' => ['Item'], 'exact' => true }
            }
          }
        }
      )

      comparison = analyzer.implicit_sites(sort).find { |derived| derived.message == '<=>' }

      expect(comparison).to have_attributes(receiver_kind: :instance, receiver_name: 'Item')
      expect(comparison.metadata).to include(
        'receiver_candidates' => ['Item'],
        'protocol_receiver' => 'element_receiver'
      )
    end

    it 'does not use spaceship comparison when sort has any comparator block' do
      %w[literal symbol_to_proc].each do |block_kind|
        sort = call_site(
          caller_id: 'Caller#run', message: 'sort', receiver_kind: :instance, receiver_name: 'Array',
          metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => block_kind }
        )

        expect(analyzer.implicit_messages(sort)).not_to include('<=>')
      end
    end

    it 'keeps spaceship comparison conservative for nil or dynamic block arguments' do
      %w[nil dynamic].each do |block_kind|
        sort = call_site(
          caller_id: 'Caller#run', message: 'sort', receiver_kind: :instance, receiver_name: 'Array',
          metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => block_kind }
        )

        expect(analyzer.implicit_messages(sort)).to include('<=>')
      end
    end

    it 'does not reinterpret literal element values as receiver type names' do
      sort = call_site(
        caller_id: 'Caller#run', message: 'sort', receiver_kind: :instance, receiver_name: 'Array',
        metadata: {
          'receiver_candidates' => ['Array'],
          'block_kind' => 'none',
          'receiver_value_fact' => {
            'kind' => 'container',
            'exact' => true,
            'summary' => {
              'element_fact' => { 'kind' => 'string_set', 'values' => %w[a z], 'exact' => true }
            }
          }
        }
      )

      comparison = analyzer.implicit_sites(sort).find { |derived| derived.message == '<=>' }

      expect(comparison).to have_attributes(receiver_kind: :unknown, receiver_name: nil)
      expect(comparison.metadata.fetch('receiver_candidates')).to eq([])
    end

    it 'keeps blockless protocol calls whose arguments define iteration behavior' do
      %w[grep inject reduce].each do |message|
        site = call_site(
          caller_id: 'Caller#run', message: message, receiver_kind: :instance, receiver_name: 'Array',
          metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => 'none' }
        )

        expect(analyzer.implicit_messages(site)).to include('each')
      end
    end

    it 'derives a distinct string conversion receiver for every output argument' do
      output = call_site(
        caller_id: 'Caller#run', message: 'puts', receiver_kind: :implicit,
        metadata: {
          'arguments' => { 'positional_count' => 2 },
          'argument_value_facts' => [
            { 'kind' => 'instance_types', 'values' => ['First'], 'exact' => true },
            { 'kind' => 'instance_types', 'values' => ['Second'], 'exact' => true }
          ]
        }
      )

      sites = analyzer.implicit_sites(output)

      expect(sites.map(&:receiver_name)).to eq(%w[First Second])
      expect(sites.map(&:call_site_id).uniq.length).to eq(2)
      expect(sites.map { |derived| derived.metadata['protocol_receiver'] }).to eq(%w[first_argument argument_1])
    end

    it 'connects scanned literal container facts through the derived protocol edge' do
      source = <<~RUBY
        class Item
          def <=>(other) = 0
        end
        class Client
          def run
            items = [Item.new, Item.new]
            items.sort
          end
        end
      RUBY

      with_project(files: { 'app/protocol.rb' => source }, config: { cache: { enabled: false } }) do |root|
        scan = scan_project(root)
        graph = graph_for_scan(scan)
        result = analyzer.analyze(graph, nil)
        comparison = result.derived_call_sites.find { |derived| derived.message == '<=>' }
        target = scan.nodes.find { |node| node.symbol_id == 'Item#<=>' }

        expect(comparison).to have_attributes(receiver_kind: :instance, receiver_name: 'Item')
        expect(result.edge_evidences).to include(have_attributes(callee_id: target.graph_id))
      end
    end

    it 'keeps sort_by comparison broad only when a block may execute' do
      %w[literal dynamic].each do |block_kind|
        site = call_site(
          caller_id: 'Caller#run', message: 'sort_by', receiver_kind: :instance, receiver_name: 'Array',
          metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => block_kind }
        )
        comparison = analyzer.implicit_sites(site).find { |derived| derived.message == '<=>' }

        expect(comparison).to have_attributes(receiver_kind: :unknown, receiver_name: nil)
      end

      blockless = call_site(
        caller_id: 'Caller#run', message: 'sort_by', receiver_kind: :instance, receiver_name: 'Array',
        metadata: { 'receiver_candidates' => ['Array'], 'block_kind' => 'none' }
      )
      expect(analyzer.implicit_sites(blockless)).to be_empty
    end
  end
end
