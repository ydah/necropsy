# frozen_string_literal: true

RSpec.describe 'why-not diagnostics' do
  def why_not_for(root, identifier)
    report = Necropsy.analyze(root: root)
    [report, Necropsy::Diagnostics.new(report).why_not(identifier)]
  end

  it 'describes a candidate with stable JSON fields and human guidance' do
    with_project(files: {
                   'lib/review_candidate.rb' => <<~RUBY
                     class ReviewCandidate
                       def unused
                       end
                     end
                   RUBY
                 }) do |root|
      _report, payload = why_not_for(root, 'ReviewCandidate#unused')
      diagnostics = Necropsy::Diagnostics.new(Necropsy.analyze(root: root))

      expect(payload).to include(
        'schema_version' => 'necropsy.why-not.v1',
        'status' => 'why_not',
        'state' => 'candidate',
        'action' => 'review',
        'classification' => 'unreachable'
      )
      expect(payload.fetch('risk_flags')).to include('public_or_protected_visibility')
      expect(payload.fetch('physical_definition')).to include(
        'symbol_id' => 'ReviewCandidate#unused', 'file' => 'lib/review_candidate.rb', 'line' => 2
      )
      expect(payload.fetch('artifact_context')).to include(
        'tool_version' => Necropsy::VERSION,
        'source_digest' => match(/\A[a-f0-9]{64}\z/),
        'definition_body_digest' => match(/\A[a-f0-9]{64}\z/),
        'configuration_sha256' => match(/\A[a-f0-9]{64}\z/)
      )
      expect(payload).to include(
        'incoming_call_sites_examined' => [],
        'target_rejection_reasons' => [],
        'blockers' => [],
        'unknown_or_partial_blockers' => [],
        'non_ruby_matches' => []
      )
      expect(payload.fetch('world_and_root_policy')).to include(
        'world' => 'application', 'load_roots' => 'known', 'reachable_domains' => []
      )
      expect(payload.dig('enabled_rules_and_types', 'analyzers').map { |profile| profile['name'] }).to eq(
        %w[name_resolution cha rta]
      )
      expect(payload.dig('suggested_next_evidence', 0, 'kind')).to eq('find_callers')
      expect(JSON.parse(diagnostics.render(payload, format: :json))).to eq(payload)
      expect(diagnostics.render(payload)).to include(
        'Why-not (candidate): ReviewCandidate#unused',
        'Incoming call sites examined: 0',
        'World/root policy: world=application load_roots=known',
        'Enabled analyzers: name_resolution(static), cha(static), rta(static)',
        'Suggested next evidence:'
      )
    end
  end

  it 'shows unknown resolution call sites and blockers that prevent a candidate conclusion' do
    handlers = (1..5).to_h do |index|
      ["lib/handler_#{index}.rb", "class Handler#{index}; def handle; end; end\n"]
    end
    files = handlers.merge(
      'lib/router.rb' => <<~RUBY,
        class Router
          def route(receiver)
            receiver.handle
          end
        end
      RUBY
      '.necropsy.yml' => <<~YAML
        analyzers:
          static: [name_resolution]
        entry_points:
          extra: [Router#route]
        cache:
          enabled: false
      YAML
    )

    with_project(files: files) do |root|
      _report, payload = why_not_for(root, 'Handler1#handle')

      expect(payload).to include('state' => 'blocked', 'classification' => 'blocked')
      expect(payload.fetch('incoming_call_sites_examined')).to contain_exactly(
        include(
          'call_site' => include('caller_id' => match(/def:v1:/), 'message' => 'handle', 'line' => 3),
          'resolution_statuses' => ['unknown'],
          'resolutions' => [include('producer' => 'name_resolution', 'status' => 'unknown')]
        )
      )
      expect(payload.fetch('resolution_status')).to include('unknown' => 1)
      expect(payload.fetch('unknown_or_partial_blockers')).not_to be_empty
      expect(payload.fetch('unknown_or_partial_blockers').map { |blocker| blocker['kind'] }).to all(
        satisfy { |kind| %w[unknown_dispatch resolution_conflict resolution_invalid partial_dispatch].include?(kind) }
      )
    end
  end

  it 'includes parse failures and parse blockers for an incomplete source' do
    with_project(files: {
                   'lib/recovered.rb' => <<~RUBY
                     class Recovered
                       def retained
                       end

                       def broken(
                     end
                   RUBY
                 }) do |root|
      _report, payload = why_not_for(root, 'Recovered#retained')
      failures = payload.fetch('parse_and_analyzer_failures')

      expect(payload).to include('state' => 'blocked')
      expect(failures.fetch('parse_failures')).to include(
        include('file' => 'lib/recovered.rb', 'type' => 'def_params_term_paren')
      )
      expect(failures.fetch('parse_blockers').map { |blocker| blocker['kind'] }).to all(eq('parse_incomplete'))
      expect(failures.fetch('analyzer_failures')).to eq([])
      expect(payload).not_to have_key('source_incompleteness')
    end
  end

  it 'attributes a global parse blocker to the failed source file' do
    with_project(files: {
                   'lib/healthy.rb' => 'class Healthy; def candidate; end; end',
                   'lib/broken.rb' => "class Broken\n  def incomplete(\nend\n"
                 }) do |root|
      _report, payload = why_not_for(root, 'Healthy#candidate')
      failures = payload.dig('parse_and_analyzer_failures', 'parse_failures')

      expect(payload).to include('state' => 'blocked')
      expect(failures).to include(include('file' => 'lib/broken.rb'))
      expect(payload.dig('parse_and_analyzer_failures', 'parse_failures')).to include(include('file' => 'lib/broken.rb'))
    end
  end

  it 'shows non-Ruby matches with their bounded source context' do
    with_project(files: {
                   'lib/template_target.rb' => <<~RUBY,
                     class TemplateTarget
                       def render_card
                       end
                     end
                   RUBY
                   'views/card.erb' => '<%= render_card %>'
                 }) do |root|
      report, payload = why_not_for(root, 'TemplateTarget#render_card')
      match = payload.fetch('non_ruby_matches').first

      expect(payload).to include('state' => 'blocked')
      expect(match).to include('kind' => 'unparsed_external_reference')
      expect(match.fetch('metadata')).to include(
        'file' => 'views/card.erb', 'line' => 1, 'match_kind' => 'method_name', 'snippet' => '<%= render_card %>'
      )
      expect(Necropsy::Diagnostics.new(report).render(payload)).to include(
        'Non-Ruby matches: 1', 'views/card.erb:1 [method_name] <%= render_card %>'
      )
    end
  end

  it 'reports analyzer failures and their recovery action' do
    failing_analyzer = Class.new(Necropsy::Analyzer) do
      def profile
        Necropsy::AnalyzerProfile.new(
          name: :failing_rule,
          kind: :static,
          soundness: :unsound,
          description: 'always fails in this regression test'
        )
      end

      def analyze(_graph, _project)
        raise 'intentional analyzer failure'
      end
    end.new

    with_project(files: {
                   'lib/failure_target.rb' => 'class FailureTarget; def review; end; end'
                 }) do |root|
      report = Necropsy::Runner.new(root: root, analyzers: [failing_analyzer]).analyze
      payload = Necropsy::Diagnostics.new(report).why_not('FailureTarget#review')
      failures = payload.dig('parse_and_analyzer_failures', 'analyzer_failures')

      expect(payload).to include('state' => 'blocked')
      expect(failures).to contain_exactly(
        include(
          'kind' => 'analyzer_failure',
          'suggested_action' => 'fix_analyzer',
          'reason' => match(/failing_rule failed.*intentional analyzer failure/)
        )
      )
      expect(payload.fetch('suggested_next_evidence')).to include(
        include('kind' => 'fix_analyzer', 'details' => match(/intentional analyzer failure/))
      )
    end
  end

  it 'distinguishes a definition reached only from a test root' do
    with_project(files: {
                   'lib/test_target.rb' => <<~RUBY,
                     class TestTarget
                       def exercised
                       end
                     end
                   RUBY
                   'spec/test_target_spec.rb' => <<~RUBY
                     TestTarget.new.exercised
                   RUBY
                 }) do |root|
      _report, payload = why_not_for(root, 'TestTarget#exercised')

      expect(payload).to include('state' => 'test_only', 'classification' => 'test_only_reachable')
      expect(payload.dig('world_and_root_policy', 'reachable_domains')).to eq(['test'])
      expect(payload.fetch('reachability_or_absence')).to include(
        'kind' => 'witness', 'domain' => 'test', 'definition_ids' => include(payload.dig('physical_definition', 'definition_id'))
      )
      expect(payload.dig('suggested_next_evidence', 0)).to include(
        'kind' => 'observe_runtime', 'details' => match(/runtime entry point/)
      )
    end
  end

  it 'bounds same-name call-site details while retaining complete counts' do
    callers = 105.times.map do |index|
      "def caller_#{index}; bounded_target; end"
    end.join("\n")
    source = <<~RUBY
      class BoundedExplanation
        def bounded_target; end
        #{callers}
      end
    RUBY

    with_project(files: { 'lib/bounded_explanation.rb' => source }) do |root|
      _report, payload = why_not_for(root, 'BoundedExplanation#bounded_target')

      expect(payload.fetch('incoming_call_sites_examined').length).to eq(100)
      expect(payload.fetch('incoming_call_site_summary')).to eq(
        'total' => 105, 'returned' => 100, 'truncated' => 5
      )
      expect(payload.fetch('limits')).to include(
        'items_per_collection' => 100, 'resolutions_per_call_site' => 20
      )
    end
  end

  it 'bounds nested duplicate-definition blocker locations' do
    definitions = 105.times.map { |index| "def repeated; #{index}; end" }.join("\n")

    with_project(files: {
                   'lib/nested_bounds.rb' => "class NestedBounds\n#{definitions}\nend\n"
                 }) do |root|
      report = Necropsy.analyze(root: root)
      definition = report.graph.definitions_for('NestedBounds#repeated').first
      payload = Necropsy::Diagnostics.new(report).why_not(definition.graph_id)
      metadata = payload.fetch('blockers').first.fetch('metadata')

      expect(metadata.fetch('locations').length).to eq(100)
      expect(metadata.dig('_bounds', 'values', 'locations', 'collection')).to eq(
        'total' => 105, 'returned' => 100, 'truncated' => 5
      )
    end
  end

  it 'bounds every string and metadata key in the complete artifact' do
    oversized = 'x' * 10_000
    target = node('BoundedArtifact#review', owner: 'BoundedArtifact', name: 'review')
    blocker = Necropsy::Blocker.new(
      kind: :unknown_dispatch,
      scope_kind: :definition,
      scope_value: target.graph_id,
      source: :oversized_rule,
      reason: oversized,
      suggested_action: :inspect_runtime,
      metadata: { oversized => oversized }
    )
    target_finding = finding(
      id: target.id, classification: :blocked, confidence: :low, score: 0.2, blockers: [blocker]
    ).with(node: target)
    graph = graph_with(nodes: [target])
    graph.add_profile(
      Necropsy::AnalyzerProfile.new(
        name: :oversized_rule,
        kind: :static,
        soundness: :partial,
        description: oversized.byteslice(0, 4_096),
        assumptions: [oversized.byteslice(0, 512)]
      )
    )
    report = Necropsy::Report.new(
      root: '/repo',
      graph: graph,
      findings: [target_finding],
      reachability: Necropsy::Reachability::Engine.new(graph).call
    )

    payload = Necropsy::Diagnostics.new(report).why_not(target.graph_id)
    strings = lambda do |value|
      case value
      when Hash then value.flat_map { |key, entry| [key] + strings.call(entry) }
      when Array then value.flat_map { |entry| strings.call(entry) }
      when String then [value]
      else []
      end
    end

    expect(strings.call(payload).map(&:bytesize).max).to be <= 4_096
    expect { JSON.generate(payload) }.not_to raise_error
  end

  it 'resolves typed metadata key collisions deterministically and reserves bounds metadata' do
    target = node('CollisionArtifact#review', owner: 'CollisionArtifact', name: 'review')
    build_payload = lambda do |metadata|
      blocker = Necropsy::Blocker.new(
        kind: :unknown_dispatch,
        scope_kind: :definition,
        scope_value: target.graph_id,
        source: :collision_rule,
        reason: 'inspect collision',
        metadata: metadata
      )
      target_finding = finding(
        id: target.id, classification: :blocked, confidence: :low, score: 0.2, blockers: [blocker]
      ).with(node: target)
      graph = graph_with(nodes: [target])
      report = Necropsy::Report.new(
        root: '/repo',
        graph: graph,
        findings: [target_finding],
        reachability: Necropsy::Reachability::Engine.new(graph).call
      )
      Necropsy::Diagnostics.new(report).why_not(target.graph_id)
    end
    entries = [['foo', 'string value'], [:foo, 'symbol value'], ['_bounds', 'user value'], ['locations', (1..105).to_a]]

    forward = build_payload.call(entries.to_h)
    reverse = build_payload.call(entries.reverse.to_h)
    metadata = forward.dig('blockers', 0, 'metadata')

    expect(forward).to eq(reverse)
    expect(metadata.keys.grep(/\Afoo/).map { |key| metadata.fetch(key) }).to contain_exactly(
      'string value', 'symbol value'
    )
    expect(metadata.values).to include('user value')
    expect(metadata.dig('_bounds', 'values', 'locations', 'collection')).to eq(
      'total' => 105, 'returned' => 100, 'truncated' => 5
    )
  end

  it 'binds the artifact to non-Ruby reference changes outside the definition body' do
    with_project(files: {
                   'lib/snapshot_target.rb' => 'class SnapshotTarget; def snapshot_target; end; end'
                 }) do |root|
      before = Necropsy::Diagnostics.new(Necropsy.analyze(root: root)).why_not('SnapshotTarget#snapshot_target')
      write_project_file(root, 'config/handler.yml', "handler: snapshot_target\n")
      after = Necropsy::Diagnostics.new(Necropsy.analyze(root: root)).why_not('SnapshotTarget#snapshot_target')

      expect(before.fetch('state')).to eq('candidate')
      expect(after.fetch('state')).to eq('blocked')
      expect(after.dig('artifact_context', 'source_digest')).not_to eq(
        before.dig('artifact_context', 'source_digest')
      )
      expect(after.dig('artifact_context', 'definition_body_digest')).to eq(
        before.dig('artifact_context', 'definition_body_digest')
      )
    end
  end

  it 'is deterministic across analyzer ordering' do
    with_project(files: {
                   'lib/order_target.rb' => 'class OrderTarget; def unused; end; end'
                 }) do |root|
      analyzers = [
        Necropsy::Analyzers::Static::NameResolution.new,
        Necropsy::Analyzers::Static::CHA.new,
        Necropsy::Analyzers::Static::RTA.new
      ]
      forward = Necropsy::Runner.new(root: root, analyzers: analyzers).analyze
      reverse = Necropsy::Runner.new(root: root, analyzers: analyzers.reverse).analyze

      forward_payload = Necropsy::Diagnostics.new(forward).why_not('OrderTarget#unused')
      reverse_payload = Necropsy::Diagnostics.new(reverse).why_not('OrderTarget#unused')
      expect(forward_payload).to eq(reverse_payload)
    end
  end

  it 'requires a physical ID and shows every same-name definition' do
    with_project(files: {
                   'lib/first.rb' => "class RepeatedTarget; def run; end; end\n",
                   'lib/second.rb' => "class RepeatedTarget; def run; end; end\n"
                 }) do |root|
      report = Necropsy.analyze(root: root)
      diagnostics = Necropsy::Diagnostics.new(report)
      definitions = report.graph.definitions_for('RepeatedTarget#run')

      expect(diagnostics.why_not('RepeatedTarget#run')).to include(
        'status' => 'ambiguous', 'definitions' => match_array(definitions.map { |node| include('definition_id' => node.graph_id) })
      )
      definitions.each do |definition|
        payload = diagnostics.why_not(definition.graph_id)
        expect(payload.fetch('same_name_definitions').map { |node| node['definition_id'] }).to match_array(
          definitions.map(&:graph_id)
        )
        expect(payload.fetch('blockers')).to include(include('kind' => 'duplicate_definition'))
      end
    end
  end

  it 'preserves explicit target rejection reasons from resolution records' do
    caller = node('Caller#route', owner: 'Caller', name: 'route')
    target = node('Target#dispatch', owner: 'Target', name: 'dispatch')
    site = call_site(
      caller_id: caller.graph_id,
      message: 'dispatch',
      receiver_kind: :unknown,
      file: 'app/caller.rb',
      line: 8
    )
    graph = graph_with(nodes: [caller, target], call_sites: [site])
    graph.add_profile(
      Necropsy::AnalyzerProfile.new(
        name: :typed_resolution,
        kind: :static,
        soundness: :partial,
        description: 'spec profile',
        assumptions: ['declared receiver types']
      )
    )
    graph.apply_result(analyzer_result(resolutions: [
                                         Necropsy::ResolutionRecord.new(
                                           resolution: Necropsy::Resolution.new(
                                             call_site_id: site.call_site_id,
                                             target_definition_ids: [],
                                             status: :unknown,
                                             unknown_scope: Necropsy::UnknownScope.new(
                                               scope_kind: :message, scope_value: 'dispatch', match: :exact
                                             ),
                                             rejected_targets: [
                                               Necropsy::RejectedTarget.new(
                                                 definition_id: target.graph_id,
                                                 reason: 'receiver type is incompatible'
                                               )
                                             ]
                                           ),
                                           producer: :typed_resolution,
                                           assumptions: ['declared receiver types']
                                         )
                                       ]))
    reachability = Necropsy::Reachability::Engine.new(graph).call
    blockers = graph.matching_blockers(target)
    target_finding = finding(
      id: target.id,
      classification: :blocked,
      confidence: :low,
      score: 0.25,
      blockers: blockers
    ).with(node: target)
    report = Necropsy::Report.new(root: '/repo', graph: graph, findings: [target_finding], reachability: reachability)

    payload = Necropsy::Diagnostics.new(report).why_not(target.graph_id)

    expect(payload.fetch('target_rejection_reasons')).to contain_exactly(
      include(
        'definition_id' => target.graph_id,
        'reason' => 'receiver type is incompatible',
        'call_site_id' => site.call_site_id,
        'producer' => 'typed_resolution'
      )
    )
    expect(payload.dig('incoming_call_sites_examined', 0, 'resolutions', 0, 'rejected_targets')).to contain_exactly(
      include('definition_id' => target.graph_id, 'reason' => 'receiver type is incompatible')
    )
  end
end
