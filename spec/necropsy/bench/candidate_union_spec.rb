# frozen_string_literal: true

require 'necropsy/bench/candidate_union'

RSpec.describe Necropsy::Bench::CandidateUnion do
  it 'loads at least thirty reviewed labels and preserves every comparison tool result' do
    repository_root = File.expand_path('../../..', __dir__)
    manifest = YAML.safe_load_file(File.join(repository_root, 'bench/corpora/v1/manifest.yml'))

    result = described_class.new(
      manifest: manifest,
      repository_root: repository_root,
      reports: {},
      diagnostics: []
    ).call

    expect(result.dig('summary', 'reviewed')).to be >= 30
    expect(result.dig('summary', 'tool_metrics', 'necropsy', 'macro_average')).to include(
      'candidate_precision_corpora' => be_a(Integer),
      'known_positive_recall_corpora' => be_positive
    )
    expect(result.fetch('candidates').filter_map { |candidate| candidate['label'] }).to all(
      include('reviewer', 'rationale', 'reviewed_at' => '2026-08-12', 'source_revision' => be_a(String))
    )
    expect(result.fetch('candidates')).to all(
      satisfy { |candidate| candidate.fetch('tool_results').keys == %w[debride necropsy spoom type_aware] }
    )
    expect(result.fetch('candidates').map { |candidate| candidate.dig('label', 'value') }.uniq).to contain_exactly(
      'dead', 'alive', 'external', 'unknown'
    )
  end

  it 'macro-averages project precision instead of weighting by candidate count' do
    reports = {
      'large' => {
        'findings' => 9.times.map do |index|
          { 'id' => "Large##{index}", 'state' => 'unreachable', 'confidence' => 'high' }
        end
      },
      'small' => { 'findings' => [{ 'id' => 'Small#only', 'state' => 'unreachable', 'confidence' => 'high' }] }
    }
    labels = {
      'labels' => [
        *9.times.map { |index| { 'corpus' => 'large', 'id' => "Large##{index}", 'value' => 'dead', 'rationale' => 'dead' } },
        { 'corpus' => 'small', 'id' => 'Small#only', 'value' => 'alive', 'rationale' => 'alive' }
      ]
    }

    with_project(files: { 'labels.yml' => labels.to_yaml }) do |root|
      result = described_class.new(
        manifest: { 'labels' => 'labels.yml', 'minimum_reviewed_labels' => 0, 'tools' => {} },
        repository_root: root,
        reports: reports,
        diagnostics: []
      ).call
      metrics = result.dig('summary', 'tool_metrics', 'necropsy')

      expect(metrics.fetch('candidate_precision')).to eq(0.9)
      expect(metrics.dig('macro_average', 'candidate_precision')).to eq(0.5)
      expect(metrics.fetch('by_corpus')).to include('large', 'small')
    end
  end

  it 'rejects labels that do not exist in any tool candidate set' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [{ 'corpus' => 'fixture', 'id' => 'Typo#missing', 'value' => 'dead',
                                    'rationale' => 'reviewed' }]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 1,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }

      expect do
        described_class.new(manifest: manifest, repository_root: root, reports: {}, diagnostics: []).call
      end.to raise_error(Necropsy::Error, /does not match a tool candidate/)
    end
  end

  it 'keeps diagnostic findings out of the candidate universe and publishes yield metrics' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [{ 'corpus' => 'fixture', 'id' => 'Sample#dead', 'value' => 'dead',
                                    'category' => 'registry', 'rationale' => 'reviewed' }],
                     'known_positives' => [
                       { 'corpus' => 'fixture', 'id' => 'Sample#dead', 'category' => 'registry',
                         'rationale' => 'confirmed removal' },
                       { 'corpus' => 'fixture', 'id' => 'Sample#missed', 'category' => 'registry',
                         'rationale' => 'seeded known dead method' }
                     ]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 1,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }
      reports = {
        'fixture' => {
          'findings' => [
            { 'id' => 'Sample#dead', 'state' => 'unreachable', 'confidence' => 'high', 'candidate' => true,
              'loc' => 5, 'category' => 'registry' },
            { 'id' => 'Sample#blocked', 'state' => 'blocked', 'confidence' => 'low', 'candidate' => false,
              'diagnostic' => true, 'unknown' => true }
          ]
        }
      }

      result = described_class.new(
        manifest: manifest, repository_root: root, reports: reports, diagnostics: []
      ).call

      expect(result.fetch('schema_version')).to eq(1)
      expect(result.fetch('candidates').map { |candidate| candidate.fetch('id') }).to eq(['Sample#dead'])
      expect(result.dig('summary', 'tool_metrics', 'necropsy')).to include(
        'candidate_precision' => 1.0,
        'precision_status' => 'measured',
        'candidate_count' => 1,
        'candidate_loc' => 5,
        'reviewed_high_candidate_count' => 1,
        'known_positive_recall' => 0.5,
        'known_positive_count' => 2
      )
      expect(result.dig('summary', 'tool_metrics', 'necropsy', 'by_category', 'registry')).to include(
        'candidate_count' => 1, 'candidate_loc' => 5, 'candidate_precision' => 1.0
      )
      expect(result.dig('summary', 'necropsy_diagnostics', 'aggregate')).to include(
        'candidate_count' => 1, 'diagnostic_count' => 1, 'blocked_count' => 1
      )
    end
  end

  it 'counts only determinate high-confidence Necropsy candidates for the public claim gate' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [
                       { 'corpus' => 'fixture', 'id' => 'Sample#high_dead', 'value' => 'dead',
                         'rationale' => 'reviewed dead method' },
                       { 'corpus' => 'fixture', 'id' => 'Sample#medium_alive', 'value' => 'alive',
                         'rationale' => 'reviewed live method' },
                       { 'corpus' => 'fixture', 'id' => 'Sample#high_unknown', 'value' => 'unknown',
                         'rationale' => 'not enough evidence' }
                     ]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 3,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }
      findings = [
        ['Sample#high_dead', 'high'], ['Sample#medium_alive', 'medium'], ['Sample#high_unknown', 'certain']
      ].map do |id, confidence|
        { 'id' => id, 'state' => 'unreachable', 'confidence' => confidence, 'candidate' => true }
      end

      result = described_class.new(
        manifest: manifest, repository_root: root, reports: { 'fixture' => { 'findings' => findings } },
        diagnostics: []
      ).call

      metrics = result.dig('summary', 'tool_metrics', 'necropsy')
      expect(metrics).to include('reviewed_high_candidate_count' => 1)
      expect(metrics.dig('by_category', 'uncategorized')).to include('reviewed_high_candidate_count' => 1)
    end
  end

  it 'marks precision as not evaluable instead of awarding perfect precision to zero candidates' do
    with_project(files: { 'labels.yml' => { 'labels' => [] }.to_yaml }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 0,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }
      reports = {
        'fixture' => {
          'findings' => [
            { 'id' => 'Sample#blocked', 'state' => 'blocked', 'confidence' => 'low', 'candidate' => false }
          ]
        }
      }

      result = described_class.new(
        manifest: manifest, repository_root: root, reports: reports, diagnostics: []
      ).call
      metrics = result.dig('summary', 'tool_metrics', 'necropsy')

      expect(metrics).to include('candidate_precision' => nil, 'precision_status' => 'no_candidates',
                                 'candidate_count' => 0, 'candidate_loc' => 0)
    end
  end

  it 'counts duplicate physical definitions separately and maps legacy tool identities explicitly' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [
                       { 'corpus' => 'fixture', 'id' => 'Duplicate#run', 'definition_id' => 'def:first',
                         'value' => 'dead', 'rationale' => 'first body is unused' },
                       { 'corpus' => 'fixture', 'id' => 'Duplicate#run', 'definition_id' => 'def:second',
                         'value' => 'alive', 'rationale' => 'second body is invoked' }
                     ]
                   }.to_yaml,
                   'external.yml' => {
                     'schema_version' => 1,
                     'tool' => 'external',
                     'provenance' => { 'version' => 'pinned' },
                     'candidates' => [{ 'corpus' => 'fixture', 'id' => 'Duplicate#run' }]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml',
        'minimum_reviewed_labels' => 2,
        'tools' => {
          'necropsy' => { 'version' => 'test' },
          'external' => { 'version' => 'test', 'snapshot' => 'external.yml' }
        }
      }
      reports = {
        'fixture' => {
          'findings' => [
            { 'id' => 'Duplicate#run', 'definition_id' => 'def:first', 'state' => 'unreachable',
              'confidence' => 'high', 'candidate' => true, 'loc' => 2 },
            { 'id' => 'Duplicate#run', 'definition_id' => 'def:second', 'state' => 'unreachable',
              'confidence' => 'high', 'candidate' => true, 'loc' => 5 }
          ]
        }
      }

      result = described_class.new(
        manifest: manifest, repository_root: root, reports: reports, diagnostics: []
      ).call

      expect(result.fetch('identity')).to include('primary' => 'definition_id', 'legacy_fallback' => 'id')
      expect(result.fetch('candidates').map { |candidate| candidate.fetch('definition_id') }).to eq(
        %w[def:first def:second]
      )
      expect(result.dig('summary', 'tool_metrics', 'necropsy')).to include(
        'candidate_count' => 2, 'candidate_loc' => 7, 'candidate_precision' => 0.5
      )
      expect(result.dig('summary', 'tool_metrics', 'external')).to include(
        'candidate_count' => 2, 'candidate_precision' => 0.5
      )
      expect(result.fetch('candidates')).to all(
        satisfy { |candidate| candidate.dig('tool_results', 'external', 'identity_match') == 'legacy_logical_fallback' }
      )
    end
  end

  it 'keeps legacy logical labels compatible while making their fan-out explicit' do
    with_project(files: {
                   'labels.yml' => {
                     'labels' => [{ 'corpus' => 'fixture', 'id' => 'Duplicate#run', 'value' => 'dead',
                                    'rationale' => 'legacy review' }]
                   }.to_yaml
                 }) do |root|
      manifest = {
        'labels' => 'labels.yml', 'minimum_reviewed_labels' => 1,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }
      findings = %w[first second].map do |suffix|
        { 'id' => 'Duplicate#run', 'definition_id' => "def:#{suffix}", 'state' => 'unreachable',
          'confidence' => 'high', 'candidate' => true }
      end

      result = described_class.new(
        manifest: manifest,
        repository_root: root,
        reports: { 'fixture' => { 'findings' => findings } },
        diagnostics: []
      ).call

      expect(result.fetch('candidates')).to all(
        satisfy { |candidate| candidate.dig('label', 'identity_match') == 'legacy_logical_fallback' }
      )
    end
  end

  it 'rejects malformed candidate collections instead of coercing them' do
    with_project(files: { 'labels.yml' => { 'labels' => [] }.to_yaml }) do |root|
      manifest = {
        'labels' => 'labels.yml', 'minimum_reviewed_labels' => 0,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }

      expect do
        described_class.new(
          manifest: manifest,
          repository_root: root,
          reports: { 'fixture' => { 'findings' => 'not-an-array' } },
          diagnostics: []
        ).call
      end.to raise_error(Necropsy::Error, /findings must be an array/)
    end
  end

  it 'rejects a scalar labels collection with a domain error' do
    with_project(files: { 'labels.yml' => { 'labels' => false }.to_yaml }) do |root|
      manifest = {
        'labels' => 'labels.yml', 'minimum_reviewed_labels' => 0,
        'tools' => { 'necropsy' => { 'version' => 'test' } }
      }

      expect do
        described_class.new(manifest: manifest, repository_root: root, reports: {}, diagnostics: []).call
      end.to raise_error(Necropsy::Error, /benchmark labels must be an array/i)
    end
  end
end
