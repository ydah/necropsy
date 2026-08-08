# frozen_string_literal: true

RSpec.describe Necropsy::FlowInterpreter do
  it 'tracks a direct constructor through a local receiver' do
    source = Prism.parse('service = Services::Runner.new; service.call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: ['Services::Runner'],
      exact: true
    )
    expect(result.issues).to eq([])
  end

  it 'widens to unknown when its step budget is exhausted' do
    source = Prism.parse('first = A.new; second = B.new; second.call').value
    result = described_class.new(constant_resolver: ->(name) { name }, max_steps: 2).analyze(source.statements)

    expect(result.return_fact).to have_attributes(kind: :unknown, exact: false, origin: 'step_budget')
    expect(result.issues).to eq(['step_budget'])
  end

  it 'joins finite constructor facts across branches' do
    source = Prism.parse(<<~RUBY).value
      if flag
        service = Service.new
      else
        service = OtherService.new
      end
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: %w[OtherService Service],
      exact: true
    )
  end

  it 'keeps transparent wrappers and safe-navigation receiver facts' do
    source = Prism.parse('service = T.let(Service.new, T.type); service&.call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: ['Service'],
      exact: true
    )
  end

  it 'returns bounded literal container summaries instead of guessing contents' do
    source = Prism.parse('registry = { fast: Service.new }; registry').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)

    expect(result.return_fact).to have_attributes(kind: :container, exact: true, origin: 'literal_hash')
    expect(result.return_fact.summary).to include('type' => 'hash', 'size' => 1)
  end
end

RSpec.describe 'FLOW01 receiver integration' do
  it 'passes only exact finite instance facts into semantic method lookup' do
    source = <<~RUBY
      class Service
        def call = :service
      end
      class Unrelated
        def call = :unrelated
      end
      class Client
        def run
          service = Service.new
          service.call
        end
      end
    RUBY

    with_project(files: { 'app/flow.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'Client#run' }
      site = scan.call_sites.find { |candidate| candidate.caller_id == caller.graph_id && candidate.message == 'call' }
      lookup = graph.method_lookup(site)

      expect(site.receiver_kind).to eq(:unknown)
      expect(site.metadata.fetch('receiver_value_fact')).to include(
        'kind' => 'instance_types', 'values' => ['Service'], 'exact' => true
      )
      expect(lookup).to be_complete
      expect(lookup.targets.map(&:symbol_id)).to eq(['Service#call'])
    end
  end
end
