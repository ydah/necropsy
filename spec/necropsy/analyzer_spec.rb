# frozen_string_literal: true

RSpec.describe Necropsy::Analyzer do
  it 'requires concrete analyzers to implement analyze and profile' do
    analyzer = described_class.new

    expect { analyzer.analyze(nil, nil) }.to raise_error(NotImplementedError, /must implement #analyze/)
    expect { analyzer.profile }.to raise_error(NotImplementedError, /must implement #profile/)
  end

  it 'emits deterministic provenance without deriving grade from weight' do
    analyzer_class = Class.new(described_class) do
      def profile
        Necropsy::AnalyzerProfile.new(
          name: :deterministic,
          kind: :static,
          soundness: :partial,
          description: 'deterministic fixture',
          version: '2.0.0',
          assumptions: %w[loaded_files closed_world]
        )
      end
    end
    analyzer = analyzer_class.new
    first = analyzer.send(
      :evidence,
      kind: :call_edge,
      details: 'resolved call',
      weight: 0.1,
      metadata: { 'line' => 3, 'file' => 'app/sample.rb' }
    )
    reordered = analyzer.send(
      :evidence,
      kind: :call_edge,
      details: 'resolved call',
      weight: 0.1,
      metadata: { 'file' => 'app/sample.rb', 'line' => 3 }
    )
    high_weight = analyzer.send(
      :evidence,
      kind: :call_edge,
      details: 'resolved call',
      weight: 1.0,
      metadata: { 'line' => 3, 'file' => 'app/sample.rb' }
    )

    expect(first).to have_attributes(
      analyzer: :deterministic,
      producer: :deterministic,
      producer_version: '2.0.0',
      grade: :heuristic,
      relation: :call_edge,
      assumptions: %w[closed_world loaded_files]
    )
    expect(first.evidence_id).to match(/\Aevidence:v1:[0-9a-f]{64}\z/)
    expect(reordered.evidence_id).to eq(first.evidence_id)
    expect(high_weight.grade).to eq(:heuristic)
    expect(high_weight.evidence_id).not_to eq(first.evidence_id)
  end

  it 'includes explicit grade, relation, source, assumptions, and scope in evidence identity' do
    analyzer_class = Class.new(described_class) do
      def profile
        Necropsy::AnalyzerProfile.new(
          name: :runtime,
          kind: :dynamic,
          soundness: :observational,
          description: 'runtime fixture',
          version: '1.0.0',
          assumptions: ['profile assumption']
        )
      end
    end
    analyzer = analyzer_class.new
    scope = Necropsy::UnknownScope.new(scope_kind: :file, scope_value: 'app/*.rb', match: :glob)
    evidence = analyzer.send(
      :evidence,
      kind: :alive,
      details: 'runtime execution',
      grade: :observed,
      relation: :execution,
      source: { 'file' => 'app/sample.rb', 'line' => 4 },
      assumptions: %w[revision_match production],
      scope: scope
    )
    changed = analyzer.send(
      :evidence,
      kind: :alive,
      details: 'runtime execution',
      grade: :observed,
      relation: :execution,
      source: { 'file' => 'app/sample.rb', 'line' => 5 },
      assumptions: %w[production revision_match],
      scope: scope
    )

    expect(evidence).to have_attributes(
      grade: :observed,
      relation: :execution,
      source: { 'file' => 'app/sample.rb', 'line' => 4 },
      assumptions: %w[production revision_match],
      scope: scope
    )
    expect(changed.evidence_id).not_to eq(evidence.evidence_id)
  end
end
