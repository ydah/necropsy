# frozen_string_literal: true

RSpec.describe Necropsy::ResolutionStore do
  def resolution_record(site_id:, targets:, status:, producer: 'flow', version: '1', assumptions: ['default'],
                        scope: nil)
    Necropsy::ResolutionRecord.new(
      resolution: Necropsy::Resolution.new(
        call_site_id: site_id,
        target_definition_ids: targets,
        status: status,
        unknown_scope: scope
      ),
      producer: producer,
      producer_version: version,
      assumptions: assumptions
    )
  end

  def unknown_scope(kind: :message, value: 'render', match: :exact)
    Necropsy::UnknownScope.new(scope_kind: kind, scope_value: value, match: match)
  end

  def apply_resolutions(graph, *records)
    records.each { |record| graph.apply_result(analyzer_result(resolutions: [record])) }
  end

  it 'distinguishes legacy results from a native empty resolution set' do
    graph = graph_with(nodes: [])

    graph.apply_result(analyzer_result)

    expect(graph.resolution_records).to eq([])
    expect(graph.observation).not_to have_key('call_site_resolutions')

    graph.apply_result(analyzer_result(resolutions: []))

    expect(graph.observation.fetch('call_site_resolutions')).to include(
      'status_counts' => { 'complete' => 0, 'partial' => 0, 'unknown' => 0 },
      'conflict_count' => 0,
      'issue_count' => 0
    )
  end

  it 'stores a complete empty resolution without creating a blocker or edge' do
    caller = node('Caller#run')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:complete-empty')
    graph = graph_with(nodes: [caller], call_sites: [site])
    record = resolution_record(site_id: site.call_site_id, targets: [], status: :complete)

    apply_resolutions(graph, record)

    expect(graph.resolution_records(site.call_site_id)).to eq([record])
    expect(graph.resolution_status_counts).to eq(complete: 1, partial: 0, unknown: 0)
    expect(graph.blockers).to eq([])
    expect(graph.edges).to eq([])
  end

  it 'keeps partial known targets while blocking only the residual scope' do
    caller = node('Caller#run')
    known = node('Known#render', owner: 'Known', name: 'render')
    residual = node('Residual#render', owner: 'Residual', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:partial')
    graph = graph_with(nodes: [caller, known, residual], call_sites: [site])
    record = resolution_record(
      site_id: site.call_site_id,
      targets: [known.graph_id],
      status: :partial,
      scope: unknown_scope
    )
    graph.add_edge(caller.graph_id, known.graph_id, evidence)

    apply_resolutions(graph, record)

    expect(graph.resolution_records.first.resolution.target_definition_ids).to eq([known.graph_id])
    expect(graph.matching_blockers(known)).to eq([])
    expect(graph.matching_blockers(residual).map(&:kind)).to eq([:partial_dispatch])
    expect(graph.edges.map(&:callee_id)).to eq([known.graph_id])
  end

  it 'keeps residual blockers distinct across assumptions and known targets' do
    caller = node('Caller#run')
    first_target = node('First#render', owner: 'First', name: 'render')
    second_target = node('Second#render', owner: 'Second', name: 'render')
    residual_target = node('Residual#render', owner: 'Residual', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:residual-identity')
    graph = graph_with(nodes: [caller, first_target, second_target, residual_target], call_sites: [site])
    first = resolution_record(
      site_id: site.call_site_id,
      targets: [first_target.graph_id],
      status: :partial,
      assumptions: ['autoload=eager'],
      scope: unknown_scope
    )
    second = resolution_record(
      site_id: site.call_site_id,
      targets: [second_target.graph_id],
      status: :partial,
      assumptions: ['autoload=lazy'],
      scope: unknown_scope
    )
    graph.add_edge(caller.graph_id, first_target.graph_id, evidence)
    graph.add_edge(caller.graph_id, second_target.graph_id, evidence)

    apply_resolutions(graph, first, second)

    blockers = graph.blockers.select { |blocker| blocker.kind == :partial_dispatch }
    expect(blockers.length).to eq(2)
    expect(blockers.map { |blocker| blocker.metadata.fetch('resolution_record_id') }.uniq.length).to eq(2)
    expect(graph.matching_blockers(first_target).length).to eq(1)
    expect(graph.matching_blockers(second_target).length).to eq(1)
    expect(graph.matching_blockers(residual_target).length).to eq(2)
  end

  it 'keeps unknown glob scopes as blockers without materializing candidate edges' do
    caller = node('Caller#run')
    matching = node('Renderer#render_pdf', owner: 'Renderer', name: 'render_pdf')
    private_matching = node('Renderer#render_secret', owner: 'Renderer', name: 'render_secret', visibility: :private)
    unrelated = node('Renderer#save', owner: 'Renderer', name: 'save')
    site = call_site(caller_id: caller.graph_id, message: 'public_send', receiver_kind: :unknown,
                     call_site_id: 'call:v1:unknown-glob')
    graph = graph_with(nodes: [caller, matching, private_matching, unrelated], call_sites: [site])
    record = resolution_record(
      site_id: site.call_site_id,
      targets: [],
      status: :unknown,
      scope: unknown_scope(value: 'render_*', match: :glob)
    )

    apply_resolutions(graph, record)

    expect(graph.matching_blockers(matching).map(&:kind)).to eq([:unknown_dispatch])
    expect(graph.matching_blockers(private_matching)).to eq([])
    expect(graph.matching_blockers(unrelated)).to eq([])
    expect(graph.edges).to eq([])
  end

  it 'retains conflicting records and their target union without deleting existing edges' do
    caller = node('Caller#run')
    first_target = node('First#render', owner: 'First', name: 'render')
    second_target = node('Second#render', owner: 'Second', name: 'render')
    unrelated_target = node('Unrelated#render', owner: 'Unrelated', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:conflict')
    graph = graph_with(nodes: [caller, first_target, second_target, unrelated_target], call_sites: [site])
    graph.add_edge(caller.graph_id, first_target.graph_id, evidence)
    graph.add_edge(caller.graph_id, second_target.graph_id, evidence)
    first = resolution_record(site_id: site.call_site_id, targets: [first_target.graph_id], status: :complete,
                              producer: 'first')
    second = resolution_record(site_id: site.call_site_id, targets: [second_target.graph_id], status: :complete,
                               producer: 'second')

    apply_resolutions(graph, first, second)

    conflict = graph.resolution_conflicts.find { |item| item['kind'] == 'complete_target_mismatch' }
    expect(conflict.fetch('target_definition_ids')).to eq([first_target.graph_id, second_target.graph_id])
    expect(graph.resolution_records.length).to eq(2)
    expect(graph.blockers.map(&:kind)).to include(:resolution_conflict)
    expect(graph.matching_blockers(first_target).map(&:kind)).to include(:resolution_conflict)
    expect(graph.matching_blockers(second_target).map(&:kind)).to include(:resolution_conflict)
    expect(graph.matching_blockers(unrelated_target).map(&:kind)).not_to include(:resolution_conflict)
    expect(graph.edges.map(&:callee_id)).to contain_exactly(first_target.graph_id, second_target.graph_id)
  end

  it 'keeps targetless conflicts diagnostic-only while residual scopes remain blocking' do
    caller = node('Caller#run')
    target = node('Target#render', owner: 'Target', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:targetless-conflict')
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    first = resolution_record(
      site_id: site.call_site_id,
      targets: [],
      status: :unknown,
      scope: unknown_scope(value: 'render')
    )
    second = resolution_record(
      site_id: site.call_site_id,
      targets: [],
      status: :unknown,
      scope: unknown_scope(value: 'render_*', match: :glob)
    )

    apply_resolutions(graph, first, second)

    expect(graph.resolution_conflicts.map { |conflict| conflict.fetch('kind') }).to include(
      'same_producer_divergence'
    )
    expect(graph.blockers.map(&:kind)).not_to include(:resolution_conflict)
    expect(graph.blockers.map(&:kind)).to all(eq(:unknown_dispatch))
  end

  it 'detects producer divergence and partial targets outside a complete set' do
    caller = node('Caller#run')
    first_target = node('First#render')
    second_target = node('Second#render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:conflict-types')
    graph = graph_with(nodes: [caller, first_target, second_target], call_sites: [site])
    producer_first = resolution_record(site_id: site.call_site_id, targets: [first_target.graph_id], status: :complete)
    producer_second = resolution_record(site_id: site.call_site_id, targets: [second_target.graph_id], status: :complete)
    partial = resolution_record(
      site_id: site.call_site_id,
      targets: [second_target.graph_id],
      status: :partial,
      producer: 'other',
      scope: unknown_scope
    )
    graph.add_edge(caller.graph_id, first_target.graph_id, evidence)
    graph.add_edge(caller.graph_id, second_target.graph_id, evidence)

    apply_resolutions(graph, producer_first, producer_second, partial)

    expect(graph.resolution_conflicts.map { |item| item['kind'] }).to include(
      'same_producer_divergence',
      'partial_target_outside_complete'
    )
  end

  it 'stores different assumptions without treating them as comparable' do
    caller = node('Caller#run')
    first_target = node('First#render')
    second_target = node('Second#render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:assumptions')
    graph = graph_with(nodes: [caller, first_target, second_target], call_sites: [site])
    first = resolution_record(site_id: site.call_site_id, targets: [first_target.graph_id], status: :complete,
                              assumptions: ['autoload=eager'])
    second = resolution_record(site_id: site.call_site_id, targets: [second_target.graph_id], status: :complete,
                               producer: 'other', assumptions: ['autoload=lazy'])
    graph.add_edge(caller.graph_id, first_target.graph_id, evidence)
    graph.add_edge(caller.graph_id, second_target.graph_id, evidence)

    apply_resolutions(graph, first, second)

    expect(graph.resolution_records.length).to eq(2)
    expect(graph.resolution_conflicts).to eq([])
  end

  it 'is deterministic when analyzer results arrive in reverse order' do
    caller = node('Caller#run')
    target = node('Target#render', owner: 'Target', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:order')
    records = [
      resolution_record(site_id: site.call_site_id, targets: [target.graph_id], status: :complete, producer: 'zeta'),
      resolution_record(site_id: site.call_site_id, targets: [], status: :unknown, producer: 'alpha',
                        scope: unknown_scope)
    ]
    forward = graph_with(nodes: [caller, target], call_sites: [site])
    reverse = graph_with(nodes: [caller, target], call_sites: [site])
    forward.add_edge(caller.graph_id, target.graph_id, evidence)
    reverse.add_edge(caller.graph_id, target.graph_id, evidence)

    apply_resolutions(forward, *records)
    apply_resolutions(reverse, *records.reverse)

    snapshot = lambda do |graph|
      {
        records: graph.resolution_records.map(&:to_h),
        conflicts: graph.resolution_conflicts,
        blockers: graph.blockers.map(&:to_h),
        diagnostic: graph.observation.fetch('call_site_resolutions')
      }
    end
    expect(snapshot.call(reverse)).to eq(snapshot.call(forward))
  end

  it 'fails closed on unknown call sites and physical targets without raising' do
    caller = node('Caller#run')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:known')
    graph = graph_with(nodes: [caller], call_sites: [site])
    unknown_site = resolution_record(site_id: 'call:v1:missing', targets: [], status: :complete)
    unknown_target = resolution_record(site_id: site.call_site_id, targets: ['Missing#render'], status: :complete,
                                       producer: 'other')

    expect { apply_resolutions(graph, unknown_site, unknown_target) }.not_to raise_error

    expect(graph.resolution_issues.map { |issue| issue['kind'] }).to contain_exactly(
      'unknown_call_site',
      'unknown_target_definition'
    )
    expect(graph.blockers.map(&:kind)).to include(:resolution_invalid)
    expect(graph.observation.fetch('call_site_resolutions')).to include('issue_count' => 2)
  end

  it 'refreshes resolution issues, blockers, and diagnostics as a target and its edge are added' do
    caller = node('Caller#run')
    missing = node('Missing#render', owner: 'Missing', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:late-target')
    graph = graph_with(nodes: [caller], call_sites: [site])
    record = resolution_record(site_id: site.call_site_id, targets: [missing.graph_id], status: :complete)

    apply_resolutions(graph, record)
    expect(graph.resolution_issues.map { |issue| issue.fetch('kind') }).to eq(['unknown_target_definition'])
    expect(graph.matching_blockers(missing).map(&:kind)).to eq([:resolution_invalid])

    graph.add_node(missing)

    expect(graph.resolution_issues.map { |issue| issue.fetch('kind') }).to eq(['missing_target_edge'])
    expect(graph.matching_blockers(missing).map(&:kind)).to eq([:resolution_invalid])

    graph.apply_result(analyzer_result(
                         edge_evidences: [
                           Necropsy::EdgeEvidence.new(
                             caller_id: caller.graph_id,
                             callee_id: missing.graph_id,
                             evidence: evidence
                           )
                         ]
                       ))

    expect(graph.resolution_issues).to eq([])
    expect(graph.blockers.map(&:kind)).not_to include(:resolution_invalid)
    expect(graph.observation.fetch('call_site_resolutions')).to include('issue_count' => 0)
  end

  %i[partial complete].each do |status|
    it "blocks a declared #{status} target when the corresponding edge is missing" do
      caller = node('Caller#run')
      target = node('Target#render', owner: 'Target', name: 'render')
      site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: "call:v1:missing-edge-#{status}")
      graph = graph_with(nodes: [caller, target], call_sites: [site])
      scope = unknown_scope if status == :partial
      record = resolution_record(
        site_id: site.call_site_id,
        targets: [target.graph_id],
        status: status,
        scope: scope
      )

      apply_resolutions(graph, record)

      expect(graph.resolution_issues).to include(
        include('kind' => 'missing_target_edge', 'definition_id' => target.graph_id)
      )
      expect(graph.matching_blockers(target)).to include(
        have_attributes(kind: :resolution_invalid, scope_kind: :definition)
      )
    end
  end

  it 'preserves reflective call visibility metadata on residual blockers' do
    caller = node('Caller#run')
    public_target = node('Public#render', owner: 'Public', name: 'render')
    protected_target = node('Protected#render', owner: 'Protected', name: 'render', visibility: :protected)
    private_target = node('Private#render', owner: 'Private', name: 'render', visibility: :private)
    record_for = lambda do |site|
      resolution_record(site_id: site.call_site_id, targets: [], status: :unknown, scope: unknown_scope)
    end

    public_send_site = call_site(
      caller_id: caller.graph_id,
      message: 'render',
      call_site_id: 'call:v1:public-send',
      metadata: { 'original_message' => 'public_send' }
    )
    public_send_graph = graph_with(
      nodes: [caller, public_target, protected_target, private_target],
      call_sites: [public_send_site]
    )
    apply_resolutions(public_send_graph, record_for.call(public_send_site))

    expect(public_send_graph.matching_blockers(public_target).map(&:kind)).to eq([:unknown_dispatch])
    expect(public_send_graph.matching_blockers(protected_target)).to eq([])
    expect(public_send_graph.matching_blockers(private_target)).to eq([])

    send_site = call_site(
      caller_id: caller.graph_id,
      message: 'render',
      call_site_id: 'call:v1:send',
      metadata: { 'original_message' => 'send' }
    )
    send_graph = graph_with(nodes: [caller, private_target], call_sites: [send_site])
    apply_resolutions(send_graph, record_for.call(send_site))
    expect(send_graph.matching_blockers(private_target).map(&:kind)).to eq([:unknown_dispatch])

    respond_to_site = call_site(
      caller_id: caller.graph_id,
      message: 'render',
      call_site_id: 'call:v1:respond-to',
      metadata: { 'original_message' => 'respond_to?', 'include_private' => true }
    )
    respond_to_graph = graph_with(nodes: [caller, private_target], call_sites: [respond_to_site])
    apply_resolutions(respond_to_graph, record_for.call(respond_to_site))
    expect(respond_to_graph.matching_blockers(private_target).map(&:kind)).to eq([:unknown_dispatch])
  end

  it 'keeps duplicated test call sites test-only and message-scoped' do
    first_caller = node('FirstSpec#run', file: 'spec/first_spec.rb', test: true)
    second_caller = node('SecondSpec#run', file: 'spec/second_spec.rb', test: true)
    production_target = node('Target#render', owner: 'Target', name: 'render')
    site_id = 'call:v1:duplicate-test'
    sites = [
      call_site(caller_id: first_caller.graph_id, message: 'render', call_site_id: site_id, test: true),
      call_site(caller_id: second_caller.graph_id, message: 'render', call_site_id: site_id, test: true)
    ]
    graph = graph_with(nodes: [first_caller, second_caller, production_target], call_sites: sites)
    record = resolution_record(site_id: site_id, targets: [], status: :complete)

    apply_resolutions(graph, record)

    blocker = graph.blockers.find { |candidate| candidate.kind == :resolution_invalid }
    expect(graph.resolution_issues.map { |issue| issue.fetch('kind') }).to eq(['ambiguous_call_site'])
    expect(blocker).to have_attributes(scope_kind: :message, scope_value: 'render')
    expect(blocker.caller_domain).to eq(:test)
    expect(graph.matching_blockers(production_target)).to eq([])
    expect(graph.matching_blockers(production_target, caller_domain: :test)).to eq([blocker])
  end

  it 'preserves the least restrictive visibility for duplicate call-site IDs independent of order' do
    caller = node('Caller#run')
    private_target = node('Private#render', owner: 'Private', name: 'render', visibility: :private)
    site_id = 'call:v1:duplicate-visibility'
    public_send = call_site(
      caller_id: caller.graph_id, message: 'render', call_site_id: site_id,
      receiver_kind: :constant, metadata: { 'original_message' => 'public_send' }
    )
    send_site = call_site(
      caller_id: caller.graph_id, message: 'render', call_site_id: site_id,
      receiver_kind: :constant, metadata: { 'original_message' => 'send' }
    )

    [
      graph_with(nodes: [caller, private_target], call_sites: [public_send, send_site]),
      graph_with(nodes: [caller, private_target], call_sites: [send_site, public_send])
    ].each do |graph|
      apply_resolutions(graph, resolution_record(site_id: site_id, targets: [], status: :complete))

      expect(graph.matching_blockers(private_target).map(&:kind)).to include(:resolution_invalid)
    end
  end

  it 'bounds fail-closed blockers for highly ambiguous mixed-domain call sites' do
    target = node('Target#message_0', owner: 'Target', name: 'message_0')
    site_id = 'call:v1:mixed-ambiguous'
    sites = 20.times.map do |index|
      call_site(
        caller_id: "Caller#{index}#run",
        message: "message_#{index}",
        call_site_id: site_id,
        test: index.odd?
      )
    end
    graph = graph_with(nodes: [target], call_sites: sites)

    apply_resolutions(graph, resolution_record(site_id: site_id, targets: [], status: :complete))

    blockers = graph.blockers.select { |blocker| blocker.kind == :resolution_invalid }
    expect(blockers.length).to eq(2)
    expect(blockers.map(&:scope_kind).uniq).to eq([:global])
    expect(blockers.map(&:caller_domain)).to contain_exactly(:runtime, :test)
    expect(graph.matching_blockers(target).map(&:kind)).to eq([:resolution_invalid])
    expect(graph.matching_blockers(target, caller_domain: :test).map(&:kind)).to eq([:resolution_invalid])
  end

  it 'keeps the bounded global fallback visibility-unrestricted and order-independent' do
    caller = node('Caller#run')
    private_target = node('Private#hidden', owner: 'Private', name: 'hidden', visibility: :private)
    site_id = 'call:v1:visibility-fallback'
    sites = 9.times.map do |index|
      call_site(
        caller_id: caller.graph_id,
        message: "message_#{index}",
        call_site_id: site_id,
        receiver_kind: :constant,
        metadata: { 'original_message' => 'public_send' }
      )
    end

    [sites, sites.reverse].each do |ordered|
      graph = graph_with(nodes: [caller, private_target], call_sites: ordered)
      apply_resolutions(graph, resolution_record(site_id: site_id, targets: [], status: :complete))

      expect(graph.matching_blockers(private_target).map(&:kind)).to include(:resolution_invalid)
    end
  end

  it 'canonicalizes mixed key types deterministically without collapsing them' do
    graph = graph_with(nodes: [])
    forward = { a: 1, 'a' => 2 }
    reverse = { 'a' => 2, a: 1 }

    expect(graph.send(:canonical_payload, forward)).to eq(graph.send(:canonical_payload, reverse))
    expect(graph.send(:canonical_payload, forward)).not_to eq(
      graph.send(:canonical_payload, { 'a' => 2 })
    )
  end

  it 'turns cyclic, deeply nested, and oversized malformed records into bounded invalid diagnostics' do
    graph = graph_with(nodes: [])
    cyclic = { 'status' => 'invalid' }
    cyclic['cycle'] = cyclic
    deeply_nested = { 'status' => 'invalid' }
    cursor = deeply_nested
    500.times do
      child = {}
      cursor['child'] = child
      cursor = child
    end
    oversized = { 'status' => 'invalid', 'items' => Array.new(20_000, 'item') }
    result_type = Struct.new(
      :edge_evidences,
      :alive_evidences,
      :uncertainties,
      :observation,
      :blockers,
      :resolutions,
      keyword_init: true
    )
    result = result_type.new(
      edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [],
      resolutions: [cyclic, deeply_nested, oversized]
    )

    expect do
      graph.apply_result(result)
    end.not_to raise_error

    expect(graph.resolution_issues.length).to eq(3)
    expect(graph.resolution_issues.map { |issue| issue.fetch('kind') }.uniq).to eq(['malformed_resolution'])
    expect(graph.blockers.map(&:kind)).to include(:resolution_invalid)
    expect(graph.observation.fetch('call_site_resolutions')).to include('issue_count' => 3)
  end

  it 'serializes equivalent malformed object values deterministically' do
    result_type = Struct.new(
      :edge_evidences,
      :alive_evidences,
      :uncertainties,
      :observation,
      :blockers,
      :resolutions,
      keyword_init: true
    )
    unstable_status = Class.new do
      def inspect
        "unstable-#{object_id}"
      end
    end
    diagnostics = 2.times.map do
      graph = graph_with(nodes: [])
      result = result_type.new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [],
        resolutions: [{ 'resolution' => { 'call_site_id' => 'call:v1:bad', 'status' => unstable_status.new } }]
      )

      graph.apply_result(result)
      graph.resolution_issues
    end

    expect(diagnostics.first).to eq(diagnostics.last)
    expect(JSON.generate(diagnostics.first)).not_to match(/unstable-\d+/)
  end

  it 'does not derive malformed diagnostic codes from arbitrary exception messages' do
    malformed_type = Class.new do
      def initialize(message)
        @message = message
      end

      def to_h
        raise @message
      end
    end
    result_type = Struct.new(
      :edge_evidences, :alive_evidences, :uncertainties, :observation, :blockers, :resolutions,
      keyword_init: true
    )
    diagnostics = ['depth', 'item count'].map do |message|
      graph = graph_with(nodes: [])
      graph.apply_result(result_type.new(
                           edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, blockers: [],
                           resolutions: [malformed_type.new(message)]
                         ))
      graph.resolution_issues
    end

    expect(diagnostics.first).to eq(diagnostics.last)
    expect(diagnostics.first.dig(0, 'record', 'canonicalization_code')).to eq('canonicalization_failure')
  end
end
