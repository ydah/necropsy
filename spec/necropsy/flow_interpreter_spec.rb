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

  it 'records exact literal array element types and call block presence for protocol summaries' do
    source = <<~RUBY
      class Item
        def <=>(other) = 0
      end
      class Client
        def run
          items = [Item.new, Item.new]
          items.sort
          items.map { |item| item }
          items.map
        end
      end
    RUBY

    with_project(files: { 'app/protocols.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      calls = scan.call_sites.select { |site| %w[sort map].include?(site.message) }
      sort = calls.find { |site| site.message == 'sort' }
      maps = calls.select { |site| site.message == 'map' }.sort_by { |site| site.metadata['block_kind'] }

      expect(sort.metadata.dig('receiver_value_fact', 'summary', 'element_fact')).to include(
        'kind' => 'instance_types', 'values' => ['Item'], 'exact' => true
      )
      expect(maps.map { |site| site.metadata['block_kind'] }).to contain_exactly('literal', 'none')
    end
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

  it 'preserves the implicit else path when a branch may not run' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      service = ReplacementService.new if enabled
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: %w[OriginalService ReplacementService],
      exact: true
    )
  end

  it 'preserves the unmatched path of a case without an else clause' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      case mode
      when :replacement
        service = ReplacementService.new
      end
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: %w[OriginalService ReplacementService],
      exact: true
    )
  end

  it 'joins the short-circuited and right-hand execution paths' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      enabled && (service = ReplacementService.new)
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: %w[OriginalService ReplacementService],
      exact: true
    )
  end

  it 'does not apply lambda body assignments when creating the lambda' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      callback = -> { service = ReplacementService.new }
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: ['OriginalService'],
      exact: true
    )
  end

  it 'does not evaluate statements after an unconditional return' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      return service
      service = ReplacementService.new
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to be_nil
    expect(result.return_fact).to have_attributes(
      kind: :instance_types,
      values: ['OriginalService'],
      exact: true
    )
  end

  it 'widens locals assigned by an unsupported loop before later use' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      while enabled
        service = ReplacementService.new
      end
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(kind: :unknown, exact: false)
  end

  it 'widens locals changed by unsupported operator assignments' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      service ||= ReplacementService.new
      service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(kind: :unknown, exact: false)
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

  it 'keeps finite interpolated strings exact within the product budget' do
    source = Prism.parse('suffix = "dump"; "do_#{suffix}"').value # rubocop:disable Lint/InterpolationCheck
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)

    expect(result.return_fact).to have_attributes(
      kind: :string_set,
      values: ['do_dump'],
      exact: true
    )
  end

  it 'resolves finite literal registry lookups to the stored value fact' do
    source = Prism.parse('registry = { fast: Service.new }; registry[:fast].call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: ['Service'],
      exact: true
    )
  end

  it 'resolves Hash#fetch as a finite registry lookup' do
    source = Prism.parse('registry = { fast: Service.new }; registry.fetch(:fast).call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: ['Service'],
      exact: true
    )
  end

  it 'distinguishes symbol and string hash keys' do
    source = Prism.parse(<<~RUBY).value
      registry = { fast: SymbolService.new, "fast" => StringService.new }
      symbol_service = registry[:fast]
      string_service = registry["fast"]
      symbol_service.call
      string_service.call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    symbol_call, string_call = source.statements.body.last(2)

    expect(result.fact_for(symbol_call.receiver).values).to eq(['SymbolService'])
    expect(result.fact_for(string_call.receiver).values).to eq(['StringService'])
  end

  it 'joins every finite hash key candidate' do
    source = Prism.parse(<<~RUBY).value
      registry = { fast: FastService.new, safe: SafeService.new }
      key = if enabled then :fast else :safe end
      registry[key].call
    RUBY
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(
      kind: :instance_types,
      values: %w[FastService SafeService],
      exact: true
    )
  end

  it 'does not resolve through a hash with a splat that may overwrite the key' do
    source = Prism.parse('registry = { fast: Service.new, **extras }; registry[:fast].call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(kind: :unknown, exact: false)
  end

  it 'does not mark a hash with a dynamic key as exact' do
    source = Prism.parse('registry = { key => Service.new }; registry[key].call').value
    result = described_class.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(kind: :unknown, exact: false)
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

  it 'resolves finite symbol dispatch through a local value fact' do
    source = <<~RUBY
      class Service
        def call = :service
      end
      class Client
        def run
          service = Service.new
          name = :call
          service.send(name)
        end
      end
    RUBY

    with_project(files: { 'app/flow_send.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'Client#run' }
      site = scan.call_sites.find { |candidate| candidate.caller_id == caller.graph_id && candidate.message == 'call' }

      expect(site).not_to be_nil
      expect(site.dynamic).to be(false)
      expect(site.metadata.fetch('finite_dynamic_dispatch')).to be(true)
      expect(graph.method_lookup(site).targets.map(&:symbol_id)).to eq(['Service#call'])
    end
  end

  it 'does not use a later literal argument as a dynamic send message' do
    source = <<~RUBY
      class Service
        def fallback = :live
      end
      class Client
        def run(service, name)
          service.send(name, :fallback)
        end
      end
    RUBY

    with_project(files: { 'app/adversarial_send.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      caller = scan.nodes.find { |node| node.symbol_id == 'Client#run' }
      sites = scan.call_sites.select { |candidate| candidate.caller_id == caller.graph_id }

      expect(sites).to be_empty
      expect(scan.uncertainties.fetch(caller.graph_id)).to include(match(/Dynamic dispatch/))
    end
  end

  it 'does not invent dynamic send messages from splats, keywords, or forwarding' do
    source = <<~RUBY
      class Client
        def splatted(service, parts)
          service.send(*parts)
        end

        def keyword(service, name)
          service.send(name, fallback: :wrong)
        end

        def forwarded(service, ...)
          service.send(...)
        end
      end
    RUBY

    with_project(files: { 'app/adversarial_sends.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      callers = scan.nodes.select { |node| node.owner == 'Client' }

      callers.each do |caller|
        expect(scan.call_sites.select { |site| site.caller_id == caller.graph_id }).to be_empty
        expect(scan.uncertainties.fetch(caller.graph_id)).to include(match(/Dynamic dispatch/))
      end
      expect(scan.call_sites.map(&:message)).not_to include('wrong', 'fallback')
    end
  end

  it 'stops exact flow after break, next, and raise transfers' do
    %w[break next raise].each do |transfer|
      source = Prism.parse(<<~RUBY).value
        service = OriginalService.new
        #{transfer}
        service = ReplacementService.new
        service.call
      RUBY
      result = Necropsy::FlowInterpreter.new(constant_resolver: ->(name) { name }).analyze(source.statements)
      call = source.statements.body.last

      expect(result.fact_for(call.receiver)).to be_nil
    end
  end

  it 'widens assignments across rescue control flow' do
    source = Prism.parse(<<~RUBY).value
      service = OriginalService.new
      begin
        risky_call
      rescue StandardError
        service = ReplacementService.new
      end
      service.call
    RUBY
    result = Necropsy::FlowInterpreter.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    call = source.statements.body.last

    expect(result.fact_for(call.receiver)).to have_attributes(kind: :unknown, exact: false)
  end

  it 'does not use unrelated same-name methods for callable registry invocation' do
    source = <<~RUBY
      class Service
        def call = :service
      end
      class Unrelated
        def call = :unrelated
      end
      class Client
        def run
          handlers = { fast: -> { Service.new } }
          handlers[:fast].call.call
        end
      end
    RUBY

    with_project(files: { 'app/callable.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      callable_site = scan.call_sites.find do |site|
        site.message == 'call' && site.metadata.dig('receiver_value_fact', 'kind') == 'callable_set'
      end
      returned_site = scan.call_sites.find do |site|
        site.message == 'call' && site.metadata.dig('receiver_value_fact', 'kind') == 'instance_types'
      end

      expect(graph.method_lookup(callable_site)).to be_unknown
      expect(graph.method_lookup(returned_site).targets.map(&:symbol_id)).to eq(['Service#call'])
    end
  end

  it 'resolves finite constant registries and reflective method callables' do
    source = <<~RUBY
      class RegistryClient
        HANDLERS = { run: method(:run) }

        def run = :ok

        def dispatch
          HANDLERS.fetch(:run).call
        end
      end
    RUBY

    with_project(files: { 'app/constant_registry.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'RegistryClient#dispatch' }
      callable_site = scan.call_sites.find do |site|
        site.caller_id == caller.graph_id && site.message == 'call' &&
          site.metadata.dig('receiver_value_fact', 'kind') == 'callable_set'
      end

      expect(callable_site.metadata.dig('receiver_value_fact', 'summary', 'reflection_kind')).to eq('method')
      expect(graph.method_lookup(callable_site).targets.map(&:symbol_id)).to eq(['RegistryClient#run'])
      expect(graph.method_lookup(callable_site)).to be_complete
    end
  end

  it 'resolves finite array registries and one-level dig lookups' do
    source = Prism.parse(<<~RUBY).value
      handlers = [FastHandler.new, SafeHandler.new]
      handlers[1].call
      registry = { fast: FastHandler.new }
      registry.dig(:fast).call
    RUBY
    result = Necropsy::FlowInterpreter.new(constant_resolver: ->(name) { name }).analyze(source.statements)
    array_call, hash_call = source.statements.body.values_at(1, 3)

    expect(result.fact_for(array_call.receiver)).to have_attributes(kind: :instance_types, values: ['SafeHandler'])
    expect(result.fact_for(hash_call.receiver)).to have_attributes(kind: :instance_types, values: ['FastHandler'])
  end

  it 'does not trust constructor flow when singleton new is overridden' do
    source = <<~RUBY
      class Constructed
        def self.new = Returned.allocate
        def initialize = :not_called
        def call = :wrong_target
      end
      class Returned
        def call = :actual_target
      end
      class Client
        def run
          service = Constructed.new
          service.call
        end
      end
    RUBY

    with_project(files: { 'app/overridden_new.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'Client#run' }
      call = scan.call_sites.find { |site| site.caller_id == caller.graph_id && site.message == 'call' }
      initialize = scan.call_sites.find do |site|
        site.caller_id == caller.graph_id && site.metadata['implicit_from'] == 'new'
      end

      expect(call.metadata.dig('receiver_value_fact', 'values')).to eq(['Constructed'])
      expect(graph.method_lookup(call)).not_to be_complete
      expect(graph.method_lookup(call).targets.map(&:symbol_id)).to contain_exactly(
        'Constructed#call', 'Returned#call'
      )
      expect(graph.method_lookup(initialize)).to have_attributes(
        status: :unknown,
        targets: [],
        reason: 'constructor_dispatch_unproven'
      )
    end
  end

  it 'does not trust constructor flow when an ancestor overrides new' do
    source = <<~RUBY
      class ParentFactory
        def self.new = Returned.allocate
      end
      class Constructed < ParentFactory
        def call = :wrong_target
      end
      class Returned
        def call = :actual_target
      end
      class Client
        def run
          service = Constructed.new
          service.call
        end
      end
    RUBY

    with_project(files: { 'app/inherited_new.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'Client#run' }
      call = scan.call_sites.find { |site| site.caller_id == caller.graph_id && site.message == 'call' }

      expect(graph.method_lookup(call)).not_to be_complete
      expect(graph.method_lookup(call).targets.map(&:symbol_id)).to contain_exactly(
        'Constructed#call', 'Returned#call'
      )
    end
  end
end
