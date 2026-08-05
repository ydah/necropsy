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

    apply_resolutions(graph, record)

    expect(graph.resolution_records.first.resolution.target_definition_ids).to eq([known.graph_id])
    expect(graph.matching_blockers(known)).to eq([])
    expect(graph.matching_blockers(residual).map(&:kind)).to eq([:partial_dispatch])
    expect(graph.edges).to eq([])
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
    site = call_site(caller_id: caller.graph_id, message: 'render', call_site_id: 'call:v1:conflict')
    graph = graph_with(nodes: [caller, first_target, second_target], call_sites: [site])
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
    expect(graph.edges.map(&:callee_id)).to contain_exactly(first_target.graph_id, second_target.graph_id)
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
end
