# frozen_string_literal: true

RSpec.describe Necropsy::Confidence::Scorer do
  describe '#findings' do
    subject(:findings) do
      described_class.new(graph: graph, reachability: reachability, project: project_for(project_root)).findings
    end

    let(:project_root) { create_project(files: files, config: config) }
    let(:files) { {} }
    let(:config) { nil }
    let(:findings_by_id) { findings.to_h { |finding| [finding.node.id, finding] } }

    context 'with runtime, dynamic, test-only, and unreachable nodes' do
      let(:live) { node('Sample#live', name: 'live') }
      let(:reachable) { node('Sample#reachable', name: 'reachable') }
      let(:test_only) { node('Sample#test_only', name: 'test_only') }
      let(:dead) { node('Sample#dead', name: 'dead') }
      let(:graph) do
        graph_with(nodes: [live, reachable, test_only, dead]).tap do |result|
          result.add_alive(live.id, evidence(kind: :alive))
          result.apply_result(analyzer_result(observation: { 'coverage' => { 'days' => 45 } }))
        end
      end
      let(:reachability) do
        Necropsy::Reachability::Result.new(
          runtime_paths: { live.id => nil, reachable.id => live.id },
          test_paths: { test_only.id => nil }
        )
      end

      it 'classifies each reachability bucket separately' do
        expect(findings_by_id).not_to include(live.id)
        expect(findings_by_id).not_to include(reachable.id)
        expect(findings_by_id.fetch(test_only.id).classification).to eq(:test_only_reachable)
        expect(findings_by_id.fetch(dead.id).classification).to eq(:unreachable)
        expect(findings_by_id.fetch(dead.id)).to have_attributes(score: 0.62, confidence: :medium)
        expect(findings_by_id.fetch(dead.id).score_components).to contain_exactly(
          have_attributes(name: 'base(unreachable)', value: 0.62),
          have_attributes(name: 'runtime_unobserved', value: 0.0)
        )
      end
    end

    context 'with multiple short runtime observations' do
      let(:reachable) { node('Sample#reachable', name: 'reachable') }
      let(:executed) { node('Sample#executed', name: 'executed') }
      let(:dead) { node('Sample#dead', name: 'dead') }
      let(:graph) do
        graph_with(nodes: [reachable, executed, dead]).tap do |result|
          result.apply_result(analyzer_result(
                                alive_evidences: [
                                  Necropsy::AliveEvidence.new(
                                    node_id: executed.id,
                                    evidence: evidence(analyzer: :coverage, kind: :alive)
                                  )
                                ],
                                observation: { 'coverage' => { 'environment' => 'production', 'days' => 1,
                                                               'started_at' => '2026-07-01T00:00:00Z' } }
                              ))
          result.apply_result(analyzer_result(
                                observation: { 'trace_point' => { 'environment' => 'staging', 'days' => 1,
                                                                  'started_at' => '2026-07-31T00:00:00Z' } }
                              ))
        end
      end
      let(:reachability) do
        Necropsy::Reachability::Result.new(runtime_paths: { reachable.id => nil }, test_paths: {})
      end

      it 'only removes candidates backed by positive evidence' do
        baseline_graph = graph_with(nodes: [reachable, executed, dead])
        baseline = described_class.new(graph: baseline_graph, reachability: reachability,
                                       project: project_for(project_root)).findings

        expect(findings.map { |finding| finding.node.id }).to eq([dead.id])
        expect(findings.map { |finding| finding.node.id } - baseline.map { |finding| finding.node.id }).to be_empty
        expect(findings.first).to have_attributes(score: 0.62, classification: :unreachable)
        expect(findings.first.score_components.map(&:name)).to include('runtime_unobserved')
        expect(graph.observation).to include(
          'coverage' => include('environment' => 'production', 'started_at' => '2026-07-01T00:00:00Z'),
          'trace_point' => include('environment' => 'staging', 'started_at' => '2026-07-31T00:00:00Z')
        )
      end
    end

    context 'with matching unresolved dispatch blockers' do
      let(:unreachable) { node('First#call', owner: 'First', name: 'call') }
      let(:test_only) { node('Second#call', owner: 'Second', name: 'call') }
      let(:blocker) do
        Necropsy::Blocker.new(
          kind: :unknown_dispatch,
          scope_kind: :message,
          scope_value: 'call',
          source: :name_resolution,
          reason: 'receiver is unknown',
          suggested_action: :review_receiver_flow,
          metadata: {
            'caller_id' => 'Router#route', 'caller_domain' => 'runtime', 'message' => 'call',
            'receiver_kind' => 'unknown', 'file' => 'app/router.rb', 'line' => 9
          }
        )
      end
      let(:graph) do
        graph_with(nodes: [unreachable, test_only]).tap do |result|
          result.apply_result(analyzer_result(blockers: [blocker]))
        end
      end
      let(:reachability) do
        Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: { test_only.id => nil })
      end

      it 'prioritizes blocked over unreachable and test-only without producing high confidence' do
        expect(findings_by_id.fetch(unreachable.id)).to have_attributes(classification: :blocked, confidence: :low)
        expect(findings_by_id.fetch(test_only.id)).to have_attributes(classification: :blocked, confidence: :low)
        expect(findings).to all(have_attributes(blockers: [blocker]))
        expect(findings).to all(satisfy { |finding| !finding.at_least?(:high) })
        expect(findings.first.score_components.map(&:name)).to include('base(blocked)', 'matching_blocker')
      end
    end

    context 'with unresolved dispatch only in tests' do
      let(:target) { node('Target#call', owner: 'Target', name: 'call') }
      let(:test_blocker) do
        Necropsy::Blocker.new(
          kind: :unknown_dispatch,
          scope_kind: :message,
          scope_value: 'call',
          source: :name_resolution,
          reason: 'test receiver is unknown',
          suggested_action: :review_receiver_flow,
          metadata: { 'caller_domain' => 'test', 'message' => 'call', 'receiver_kind' => 'unknown' }
        )
      end
      let(:graph) do
        graph_with(nodes: [target]).tap { |result| result.apply_result(analyzer_result(blockers: [test_blocker])) }
      end
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }

      it 'does not overblock a production candidate' do
        expect(findings.first).to have_attributes(classification: :unreachable, blockers: [])
      end
    end

    context 'when the ambiguity limit shrinks' do
      let(:graph) { graph_with(nodes: []) }
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }

      it 'does not increase candidate or high-confidence sets' do
        caller = node('Router#route', owner: 'Router', name: 'route')
        targets = 5.times.map { |index| node("Handler#{index}#call", owner: "Handler#{index}", name: 'call') }
        site = call_site(caller_id: caller.id, message: 'call', receiver_kind: :unknown)

        findings_by_limit = [Float::INFINITY, 4].to_h do |limit|
          scoped_graph = graph_with(nodes: [caller, *targets], call_sites: [site], ambiguity_limit: limit)
          scoped_graph.apply_result(Necropsy::Analyzers::Static::NameResolution.new.analyze(scoped_graph, nil))
          scoped_findings = described_class.new(
            graph: scoped_graph,
            reachability: Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}),
            project: project_for(project_root)
          ).findings
          [limit, scoped_findings]
        end

        unlimited_candidates = findings_by_limit.fetch(Float::INFINITY).select do |finding|
          finding.classification == :unreachable
        end.to_set { |finding| finding.node.id }
        limited_candidates = findings_by_limit.fetch(4).select do |finding|
          finding.classification == :unreachable
        end.to_set { |finding| finding.node.id }
        unlimited_high = findings_by_limit.fetch(Float::INFINITY).select { |finding| finding.at_least?(:high) }.to_set
        limited_high = findings_by_limit.fetch(4).select { |finding| finding.at_least?(:high) }.to_set

        expect(limited_candidates).to be_subset(unlimited_candidates)
        expect(limited_high).to be_subset(unlimited_high)
        expect(findings_by_limit.fetch(4).count { |finding| finding.classification == :blocked }).to eq(5)
      end
    end

    context 'near metaprogramming and generated accessors' do
      let(:generated) { node('Sample#name', name: 'name', defined_via: :attr_reader) }
      let(:graph) do
        graph_with(
          nodes: [generated],
          uncertainties: { generated.id => ['Dynamic dispatch nearby'] },
          class_infos: [class_info('Sample', dynamic: true)]
        )
      end
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }

      it 'lowers confidence and explains why' do
        finding = findings.first

        expect(finding.classification).to eq(:unreachable)
        expect(finding.confidence).to eq(:low)
        expect(finding.reasons.join("\n")).to include('metaprogramming', 'dynamic dispatch', 'accessor DSL')
      end
    end

    context 'with a quarantine annotation' do
      let(:files) do
        {
          'app/quarantined.rb' => <<~RUBY
            class Quarantined
              # necropsy:quarantine since=#{since} reason=cleanup owner=team issue=123 #{fingerprint_clause}
              def dead
              end
            end
          RUBY
        }
      end
      let(:since) { (Date.today - 31).iso8601 }
      let(:fingerprint) { Digest::SHA256.hexdigest('unreachable:Quarantined#dead') }
      let(:fingerprint_clause) { "fingerprint=#{fingerprint}" }
      let(:dead) { node('Quarantined#dead', owner: 'Quarantined', name: 'dead', file: 'app/quarantined.rb', line: 3) }
      let(:graph) { graph_with(nodes: [dead]) }
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }

      it 'marks the day after expiry for review without changing deadness' do
        expect(findings.first).to have_attributes(
          classification: :unreachable,
          score: 0.62,
          confidence: :medium
        )
        expect(findings.first.score_components).to include(
          have_attributes(name: 'quarantine_review_required', value: 0.0)
        )
      end

      context 'at the expiry boundary' do
        let(:since) { (Date.today - 30).iso8601 }

        it 'requires review without changing deadness' do
          expect(findings.first).to have_attributes(
            classification: :unreachable,
            score: 0.62,
            confidence: :medium
          )
          expect(findings.first.score_components.map(&:name)).to include('quarantine_review_required')
        end
      end

      context 'immediately before expiry' do
        let(:since) { (Date.today - 29).iso8601 }

        it 'keeps the same state and does not require review' do
          expect(findings.first).to have_attributes(
            classification: :unreachable,
            score: 0.62,
            confidence: :medium
          )
          expect(findings.first.score_components.map(&:name)).not_to include('quarantine_review_required')
        end
      end

      context 'with an invalid date in an existing annotation' do
        let(:since) { 'not-a-date' }

        it 'adds one bounded diagnostic without changing deadness' do
          expect(findings.first).to have_attributes(
            classification: :unreachable,
            score: 0.62,
            confidence: :medium
          )
          expect(findings.first.score_components).to include(
            have_attributes(name: 'quarantine_invalid_date', value: 0.0)
          )
          expect(findings.first.reasons.grep(/invalid since date/).length).to eq(1)
        end
      end

      context 'with a fingerprint for a different physical definition' do
        let(:fingerprint) { '0' * 64 }

        it 'marks the annotation stale instead of applying its expiry' do
          expect(findings.first.score_components.map(&:name)).to include('quarantine_stale_fingerprint')
          expect(findings.first.score_components.map(&:name)).not_to include('quarantine_review_required')
        end
      end

      context 'with a legacy annotation lacking a fingerprint' do
        let(:fingerprint_clause) { '' }

        it 'requires migration instead of ambiguously applying the annotation' do
          expect(findings.first.score_components.map(&:name)).to include('quarantine_fingerprint_required')
          expect(findings.first.score_components.map(&:name)).not_to include('quarantine_review_required')
        end
      end

      context 'with each operational expiry policy' do
        it 'keeps the analysis result identical' do
          states = %w[warn fail ignore].map do |policy|
            finding = described_class.new(
              graph: graph,
              reachability: reachability,
              project: project_for(create_project(files: files, config: { quarantine: { expiry: policy } }))
            ).findings.first
            [finding.classification, finding.score, finding.confidence, finding.score_components.map(&:name)]
          end

          expect(states.uniq.length).to eq(1)
        end
      end
    end

    context 'with methods invoked implicitly' do
      let(:protocol) { node('Sample#to_s', name: 'to_s') }
      let(:ordinary_each) { node('Sample#each', name: 'each') }
      let(:callback) { node('FrameworkCallback#on_send', owner: 'FrameworkCallback', name: 'on_send') }
      let(:callback_helper) { node('FrameworkCallback#helper', owner: 'FrameworkCallback', name: 'helper') }
      let(:rubocop_callback) { node('RuboCopCallback#on_def', owner: 'RuboCopCallback', name: 'on_def') }
      let(:graph) do
        graph_with(
          nodes: [protocol, ordinary_each, callback, callback_helper, rubocop_callback],
          class_infos: [
            class_info('Framework::Base'),
            class_info('ConcreteCallback', superclass: 'Framework::Base', includes: ['FrameworkCallback']),
            class_info('FrameworkCallback', kind: :module),
            class_info('RuboCop::Cop::Base'),
            class_info('ConcreteCop', superclass: 'RuboCop::Cop::Base', includes: ['RuboCopCallback']),
            class_info('RuboCopCallback', kind: :module)
          ]
        ).tap { |result| result.add_edge(callback.id, callback_helper.id, evidence) }
      end
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }
      let(:config) do
        {
          implicit_callers: [
            { name_pattern: '^on_', owner_ancestors: ['Framework::Base'], reason: 'framework callback' }
          ]
        }
      end

      it 'lowers confidence for Ruby protocols and configured callbacks' do
        expect(findings_by_id.fetch(protocol.id).confidence).to eq(:low)
        expect(findings_by_id.fetch(protocol.id).reasons).to include(match(/Ruby protocol/))
        expect(findings_by_id.fetch(ordinary_each.id).confidence).to eq(:medium)
        expect(findings_by_id.fetch(ordinary_each.id).reasons).not_to include(match(/Ruby protocol/))
        expect(findings_by_id.fetch(callback.id).confidence).to eq(:low)
        expect(findings_by_id.fetch(callback.id).reasons).to include(match(/framework callback/))
        expect(findings_by_id.fetch(rubocop_callback.id).confidence).to eq(:low)
        expect(findings_by_id.fetch(rubocop_callback.id).reasons).to include(match(/RuboCop Commissioner/))
        expect(findings_by_id.fetch(callback_helper.id).confidence).to eq(:low)
        expect(findings_by_id.fetch(callback_helper.id).reasons).to include(match(/reachable from implicitly invoked/))
      end
    end

    context 'when a statically unreachable node was observed dynamically' do
      let(:executed) { node('Sample#executed', name: 'executed') }
      let(:graph) do
        graph_with(nodes: [executed]).tap do |result|
          result.add_alive(executed.id, evidence(analyzer: :coverage, kind: :alive))
        end
      end
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_paths: {}, test_paths: {}) }

      it 'does not report the executed node as dead' do
        expect(findings).to be_empty
      end
    end

    context 'when a generated accessor is statically reachable but absent from dynamic data' do
      let(:accessor) { node('Sample#name', name: 'name', defined_via: :attr_reader) }
      let(:observed) { node('Sample#run', name: 'run') }
      let(:graph) do
        graph_with(nodes: [accessor, observed]).tap do |result|
          result.add_alive(observed.id, evidence(analyzer: :coverage, kind: :alive))
        end
      end
      let(:reachability) do
        Necropsy::Reachability::Result.new(
          runtime_paths: { accessor.id => nil, observed.id => nil },
          test_paths: {}
        )
      end

      it 'does not infer unused from evidence that cannot observe accessors' do
        expect(findings).to be_empty
      end
    end
  end
end
