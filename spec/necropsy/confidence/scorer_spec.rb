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
      let(:unused) { node('Sample#unused', name: 'unused') }
      let(:test_only) { node('Sample#test_only', name: 'test_only') }
      let(:dead) { node('Sample#dead', name: 'dead') }
      let(:graph) do
        graph_with(nodes: [live, unused, test_only, dead]).tap do |result|
          result.add_alive(live.id, evidence(kind: :alive))
          result.apply_result(analyzer_result(observation: { 'coverage' => { 'days' => 45 } }))
        end
      end
      let(:reachability) do
        Necropsy::Reachability::Result.new(
          runtime_alive: Set[live.id, unused.id],
          test_alive: Set[test_only.id]
        )
      end

      it 'classifies each reachability bucket separately' do
        expect(findings_by_id).not_to include(live.id)
        expect(findings_by_id.fetch(unused.id).classification).to eq(:unused)
        expect(findings_by_id.fetch(test_only.id).classification).to eq(:test_only_reachable)
        expect(findings_by_id.fetch(dead.id).classification).to eq(:unreachable)
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
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_alive: Set[], test_alive: Set[]) }

      it 'lowers confidence and explains why' do
        finding = findings.first

        expect(finding.classification).to eq(:unreachable)
        expect(finding.confidence).to eq(:low)
        expect(finding.reasons.join("\n")).to include('metaprogramming', 'dynamic dispatch', 'accessor DSL')
      end
    end

    context 'with an expired quarantine annotation' do
      let(:files) do
        {
          'app/quarantined.rb' => <<~RUBY
            class Quarantined
              # necropsy:quarantine since=2000-01-01
              def dead
              end
            end
          RUBY
        }
      end
      let(:dead) { node('Quarantined#dead', owner: 'Quarantined', name: 'dead', file: 'app/quarantined.rb', line: 3) }
      let(:graph) do
        graph_with(nodes: [dead]).tap do |result|
          result.apply_result(analyzer_result(observation: { 'coverage' => { 'days' => 90 } }))
        end
      end
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_alive: Set[], test_alive: Set[]) }

      it 'raises confidence to certain' do
        expect(findings.first.confidence).to eq(:certain)
        expect(findings.first.reasons).to include(match(/quarantine annotation has expired/))
      end
    end

    context 'with methods invoked implicitly' do
      let(:protocol) { node('Sample#to_s', name: 'to_s') }
      let(:callback) { node('FrameworkCallback#on_send', owner: 'FrameworkCallback', name: 'on_send') }
      let(:callback_helper) { node('FrameworkCallback#helper', owner: 'FrameworkCallback', name: 'helper') }
      let(:rubocop_callback) { node('RuboCopCallback#on_def', owner: 'RuboCopCallback', name: 'on_def') }
      let(:graph) do
        graph_with(
          nodes: [protocol, callback, callback_helper, rubocop_callback],
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
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_alive: Set[], test_alive: Set[]) }
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
      let(:reachability) { Necropsy::Reachability::Result.new(runtime_alive: Set[], test_alive: Set[]) }

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
        Necropsy::Reachability::Result.new(runtime_alive: Set[accessor.id, observed.id], test_alive: Set[])
      end

      it 'does not infer unused from evidence that cannot observe accessors' do
        expect(findings).to be_empty
      end
    end
  end
end
