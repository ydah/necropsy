# frozen_string_literal: true

RSpec.describe Necropsy::Bench::ClaimGate do
  let(:reports) do
    {
      'plain' => {
        'findings' => [
          {
            'id' => 'Sample#dead', 'definition_id' => 'def:dead', 'path' => 'lib/sample.rb', 'line' => 2,
            'state' => 'unreachable', 'candidate' => true, 'confidence' => 'high',
            'category' => 'plain', 'reasons' => ['no reachable caller']
          }
        ]
      }
    }
  end

  let(:summary) do
    {
      'candidate_union' => {
        'tool_metrics' => {
          'necropsy' => {
            'precision_status' => 'measured', 'candidate_precision' => 1.0,
            'candidate_count' => 1, 'candidate_loc' => 3, 'reviewed_high_candidate_count' => 1
          }
        }
      }
    }
  end

  it 'enforces corpus, category, explanation, yield, and adversarial checks when configured' do
    result = described_class.new(
      config: {
        'claim_gate' => {
          'minimum_corpora' => 1,
          'required_categories' => ['plain'],
          'minimum_reviewed_high' => 1
        }
      },
      reports: reports,
      summary: summary,
      adversarial_results: [{ 'name' => 'safety', 'passed' => true }]
    ).call

    expect(result).to include('enforced' => true, 'passed' => true)
    expect(result.fetch('checks').values).to all(be(true))
  end

  it 'fails closed on an unexplained high candidate and failed suite' do
    report = Marshal.load(Marshal.dump(reports))
    report['plain']['findings'].first['reasons'] = []
    result = described_class.new(
      config: { 'claim_gate' => { 'minimum_corpora' => 1 } },
      reports: report,
      summary: summary,
      adversarial_results: [{ 'name' => 'safety', 'passed' => false }]
    ).call

    expect(result).to include('passed' => false)
    expect(result.fetch('unexplained_high_candidates')).not_to be_empty
  end

  it 'is disabled without an explicit claim policy' do
    result = described_class.new(config: {}, reports: {}, summary: {}, adversarial_results: []).call

    expect(result).to include('enforced' => false, 'passed' => true)
  end
end
