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
