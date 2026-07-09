# frozen_string_literal: true

RSpec.describe Necropsy::Confidence::Scorer do
  describe '#findings' do
    subject(:findings) do
      described_class.new(graph: graph, reachability: reachability, project: project_for(project_root)).findings
    end

    let(:project_root) { create_project(files: files) }
    let(:files) { {} }
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
  end
end
