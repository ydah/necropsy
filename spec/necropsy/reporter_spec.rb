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
        expect(rendered).to include('Necropsy report', 'Findings: 1', '[high] Sample#dead app/sample.rb:3')
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
        report_with_findings([
                               finding(id: 'Sample#dead', confidence: :high, classification: :unreachable,
                                       file: 'app/sample.rb', line: 3)
                             ])
      end

      it 'renders workflow warning commands' do
        expect(rendered).to eq(
          '::warning file=app/sample.rb,line=3,title=Necropsy high::unreachable Sample#dead confidence=high'
        )
      end
    end

    context 'with SARIF output' do
      let(:format) { :sarif }
      let(:report) do
        report_with_findings([
                               finding(id: 'Sample#dead', confidence: :certain, classification: :unreachable, file: 'app/sample.rb',
                                       line: 3),
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
