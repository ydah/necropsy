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

    context 'with GitHub annotations' do
      let(:format) { :github }
      let(:report) do
        report_with_findings([
          finding(id: 'Sample#dead', confidence: :high, classification: :unreachable, file: 'app/sample.rb', line: 3)
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
          finding(id: 'Sample#dead', confidence: :certain, classification: :unreachable, file: 'app/sample.rb', line: 3),
          finding(id: 'Sample#maybe', confidence: :low, classification: :unused, file: 'app/sample.rb', line: 8)
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
  end
end
