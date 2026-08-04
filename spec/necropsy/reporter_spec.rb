# frozen_string_literal: true

RSpec.describe Necropsy::Reporter do
  describe '#render' do
    subject(:rendered) { described_class.new(report).render(format: format, min_confidence: min_confidence) }

    let(:min_confidence) { :low }

    context 'with human output' do
      let(:format) { :human }
      let(:min_confidence) { :high }
      let(:report) do
        report_with_findings([
                               finding(id: 'Sample#dead', confidence: :high, file: 'app/sample.rb', line: 3),
                               finding(id: 'Sample#maybe', confidence: :low, file: 'app/sample.rb', line: 8)
                             ])
      end

      it 'renders only findings at or above the requested confidence' do
        expect(rendered).to include('Necropsy report', 'Findings: 1', '[high] Sample#dead [Sample#dead] app/sample.rb:3')
        expect(rendered).not_to include('Sample#maybe')
      end
    end

    context 'with partially matched dynamic evidence' do
      let(:format) { :human }
      let(:report) do
        full_caller = node('FullCaller#run')
        full_callee = node('FullCallee#run')
        partial_caller = node('PartialCaller#run')
        graph = graph_with(nodes: [node('Sample#live'), full_caller, full_callee, partial_caller])
        dynamic_edge = evidence(analyzer: :coverage, kind: :call_edge)
        result = analyzer_result(
          edge_evidences: [
            Necropsy::EdgeEvidence.new(
              caller_id: full_caller.id, callee_id: full_callee.id, evidence: dynamic_edge
            ),
            Necropsy::EdgeEvidence.new(
              caller_id: partial_caller.id, callee_id: 'MissingCallee#run', evidence: dynamic_edge
            ),
            Necropsy::EdgeEvidence.new(
              caller_id: 'MissingCaller#run', callee_id: 'OtherMissingCallee#run', evidence: dynamic_edge
            )
          ],
          alive_evidences: [
            Necropsy::AliveEvidence.new(node_id: 'Sample#live', evidence: evidence(kind: :alive)),
            Necropsy::AliveEvidence.new(node_id: 'Other#live', evidence: evidence(kind: :alive))
          ],
          observation: { 'coverage' => { 'environment' => 'production' } }
        )
        graph.apply_result(result)
        report_with_findings([], graph: graph)
      end

      it 'renders match counts and an unmatched sample' do
        output = nil

        expect { output = rendered }.to output(
          /matched 1 of 2 dynamic node IDs.*fully matched 1 of 3 dynamic edges; partially matched 1; unmatched 1/m
        ).to_stderr
        expect(output).to include(
          'Dynamic evidence (positive-only): nodes attempted=2 matched=1 partial=0 unmatched=1; ' \
          'edges attempted=3 matched=1 partial=1 unmatched=1',
          'Unmatched dynamic evidence: Other#live, '
        )
        diagnostic = report.to_h.fetch('diagnostics').fetch('dynamic_evidence')
        expect(diagnostic).to include(
          'attempted' => { 'nodes' => 2, 'edges' => 3 },
          'matched' => { 'nodes' => 1, 'edges' => 1 },
          'partially_matched' => { 'nodes' => 0, 'edges' => 1 },
          'unmatched' => { 'nodes' => 1, 'edges' => 1 }
        )
        %w[nodes edges].each do |kind|
          expect(diagnostic.dig('attempted', kind)).to eq(
            diagnostic.dig('matched', kind) + diagnostic.dig('partially_matched', kind) +
            diagnostic.dig('unmatched', kind)
          )
        end
      end
    end

    context 'with a blocked finding' do
      let(:format) { :human }
      let(:min_confidence) { :high }
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
            'file' => 'app/router.rb', 'line' => 12
          }
        )
      end
      let(:report) do
        report_with_findings([
                               finding(id: 'Handler#call', classification: :blocked, confidence: :low,
                                       file: 'app/handler.rb', line: 4, blockers: [blocker])
                             ])
      end

      it 'keeps blocker diagnostics visible independently of candidate confidence filtering' do
        expect(rendered).to include(
          'blocked (1)',
          '[low] Handler#call [Handler#call] app/handler.rb:4',
          'blocker unknown_dispatch at app/router.rb:12 caller=Router#route',
          'scope message="call" message=call',
          'reason receiver is unknown'
        )
      end

      it 'serializes blockers in JSON findings' do
        payload = JSON.parse(described_class.new(report).render(format: :json))

        expect(payload.dig('findings', 0, 'blockers', 0)).to include(
          'kind' => 'unknown_dispatch', 'scope_kind' => 'message', 'reason' => 'receiver is unknown'
        )
      end
    end

    context 'without an explicit confidence threshold' do
      let(:report) do
        report_with_findings([
                               finding(id: 'Sample#dead', confidence: :medium),
                               finding(id: 'Sample#maybe', confidence: :low)
                             ])
      end

      it 'omits low-confidence findings by default' do
        output = described_class.new(report).render

        expect(output).to include('Findings: 1', 'Sample#dead')
        expect(output).not_to include('Sample#maybe')
      end
    end

    context 'with GitHub annotations' do
      let(:format) { :github }
      let(:report) do
        logical = finding(
          id: 'Sample#dead', confidence: :high, classification: :unreachable, file: 'app/sample.rb', line: 3
        )
        physical = logical.with(node: logical.node.with(definition_id: 'def:v1:dead'))
        report_with_findings([physical])
      end

      it 'renders workflow warning commands' do
        expect(rendered).to eq(
          '::warning file=app/sample.rb,line=3,title=Necropsy high::unreachable Sample#dead ' \
          'definition_id=def:v1:dead confidence=high'
        )
      end
    end

    context 'with only an incomplete source diagnostic' do
      let(:source_error) do
        Necropsy::SourceError.new(
          file: 'lib/broken.rb', line: 4, message: 'unexpected end-of-input', type: :unexpected_token
        )
      end
      let(:root_node) do
        node('file:lib/broken.rb', kind: :block_entry, file: 'lib/broken.rb', owner: nil, name: 'lib/broken.rb')
      end
      let(:graph) do
        result = scan_result(nodes: [root_node]).with(
          file_statuses: { 'lib/broken.rb' => :recovered }, source_errors: [source_error]
        )
        Necropsy::CallGraph.new(result)
      end
      let(:report) { report_with_findings([], graph: graph) }

      it 'emits a GitHub annotation independently of the finding threshold' do
        output = described_class.new(report).render(format: :github, min_confidence: :certain)

        expect(report.findings).to eq([])
        expect(output).to include(
          'file=lib/broken.rb,line=4,title=Necropsy incomplete source',
          'Incomplete source (recovered, unexpected_token): unexpected end-of-input'
        )
      end

      it 'emits a SARIF result and rule without a dead-code finding' do
        payload = JSON.parse(described_class.new(report).render(format: :sarif, min_confidence: :certain))
        run = payload.fetch('runs').first

        expect(run.dig('tool', 'driver', 'rules')).to include(include('id' => 'parse_incomplete'))
        expect(run.fetch('results')).to contain_exactly(
          include(
            'ruleId' => 'parse_incomplete',
            'level' => 'warning',
            'locations' => [include('physicalLocation' => include(
              'artifactLocation' => { 'uri' => 'lib/broken.rb' },
              'region' => { 'startLine' => 4 }
            ))]
          )
        )
      end
    end

    context 'with SARIF output' do
      let(:format) { :sarif }
      let(:report) do
        dead = finding(
          id: 'Sample#dead', confidence: :certain, classification: :unreachable, file: 'app/sample.rb', line: 3
        )
        dead = dead.with(node: dead.node.with(definition_id: 'def:v1:dead'))
        report_with_findings([
                               dead,
                               finding(id: 'Sample#maybe', confidence: :low, classification: :unused,
                                       file: 'app/sample.rb', line: 8)
                             ])
      end
      let(:payload) { JSON.parse(rendered) }
      let(:results) { payload.fetch('runs').first.fetch('results') }

      it 'maps findings into SARIF results and levels' do
        expect(payload).to include('version' => '2.1.0')
        expect(results.map { |result| result.fetch('level') }).to contain_exactly('error', 'note')
        expect(results.first.fetch('partialFingerprints')).to include('necropsy')
        dead_result = results.find { |result| result.dig('properties', 'definitionId') == 'def:v1:dead' }
        expect(dead_result.fetch('properties')).to eq(
          'symbolId' => 'Sample#dead', 'definitionId' => 'def:v1:dead'
        )
        expect(dead_result.dig('partialFingerprints', 'necropsy')).to eq(report.findings.first.fingerprint)
      end
    end

    context 'with definition-resolution ambiguity' do
      let(:format) { :human }
      let(:report) do
        graph = graph_with(nodes: [])
        graph.observation['definition_resolution'] = {
          'ambiguous_input_count' => 6,
          'ambiguous_inputs' => 6.times.map do |index|
            {
              'kind' => 'alive', 'identifier' => "Repeated#{index}#run",
              'definition_ids' => ["def:v1:#{index}-a", "def:v1:#{index}-b"]
            }
          end
        }
        report_with_findings([], graph: graph)
      end

      it 'renders a bounded summary of ambiguous inputs' do
        expect(rendered).to include(
          'Ambiguous definition inputs: 6',
          'alive Repeated0#run -> def:v1:0-a, def:v1:0-b',
          '... 1 more'
        )
        expect(rendered).not_to include('Repeated5#run')
      end
    end

    context 'with a graph-recorded definition-resolution ambiguity' do
      let(:format) { :human }
      let(:report) do
        first = node('Repeated#run', definition_id: 'def:v1:first')
        second = node('Repeated#run', definition_id: 'def:v1:second')
        graph = graph_with(nodes: [first, second])
        graph.add_alive('Repeated#run', evidence(kind: :alive))
        report_with_findings([], graph: graph)
      end

      it 'summarizes the current graph observation shape' do
        expect(rendered).to include(
          'Ambiguous definition inputs: 1',
          'alive Repeated#run -> def:v1:first, def:v1:second'
        )
      end
    end

    context 'with ambiguous dynamic evidence' do
      let(:format) { :human }
      let(:report) do
        first = node('Repeated#run', definition_id: 'def:v1:first')
        second = node('Repeated#run', definition_id: 'def:v1:second')
        graph = graph_with(nodes: [first, second])
        graph.apply_result(
          analyzer_result(
            alive_evidences: [
              Necropsy::AliveEvidence.new(node_id: 'Repeated#run', evidence: evidence(kind: :alive))
            ]
          )
        )
        report_with_findings([], graph: graph)
      end

      it 'renders the ambiguous runtime reference and every physical candidate' do
        expect(rendered).to include(
          'Ambiguous runtime references: 1',
          'Repeated#run -> def:v1:first, def:v1:second'
        )
      end
    end

    context 'with an unknown format' do
      let(:format) { :xml }
      let(:report) { report_with_findings([]) }

      it 'raises a helpful error' do
        expect { rendered }.to raise_error(Necropsy::Error, /Unknown report format: xml/)
      end
    end

    context 'with JSON output' do
      let(:format) { :json }
      let(:report) { report_with_findings([finding]) }

      it 'omits the graph by default' do
        expect(JSON.parse(rendered)).not_to have_key('graph')
        with_graph = described_class.new(report).render(format: :json, include_graph: true)
        expect(JSON.parse(with_graph)).to include('graph' => include('nodes'))
      end
    end
  end
end
