# frozen_string_literal: true

require 'necropsy/bench/release_audit'
require 'necropsy/bench/release_audit/adversarial_runner'
require 'necropsy/bench/release_audit/artifact_writer'
require 'necropsy/bench/release_audit/config_validator'
require 'necropsy/bench/release_audit/git_snapshot'
require 'necropsy/bench/release_audit/run_provenance'
require 'fileutils'
require 'rbconfig'
require 'tempfile'
require 'tmpdir'

RSpec.describe Necropsy::Bench::ReleaseAudit do
  def finding(id, state: 'unreachable', confidence: 'medium')
    { 'id' => id, 'path' => 'lib/sample.rb', 'line' => 1, 'state' => state, 'confidence' => confidence,
      'reasons' => [] }
  end

  def report(*findings)
    { 'metrics' => { 'findings' => findings.length }, 'findings' => findings }
  end

  def audit_inputs(baseline:, current:, labels: {}, reviews: [], current_performance: {}, adversarial: nil)
    config = {
      'schema_version' => 1,
      'release' => '0.2.1',
      'corpora' => ['sample'],
      'baseline' => { 'git_ref' => 'baseline', 'reason' => 'spec baseline' },
      'review' => { 'corpora' => { 'sample' => { 'strategy' => 'all' } } },
      'performance' => {
        'wall_time_ratio' => 1.5,
        'wall_time_allowance_seconds' => 0.25,
        'max_wall_time_seconds' => { 'sample' => 5.0 },
        'rss_ratio' => 1.25,
        'rss_allowance_kb' => 1024,
        'max_rss_kb' => 20_000
      },
      'adversarial_suites' => { 'spec' => { 'command' => ['true'] } }
    }
    environment = {
      'ruby' => RUBY_DESCRIPTION,
      'os' => 'spec-os',
      'command' => 'spec-command',
      'rss_kind' => 'current_process_rss_after_corpus',
      'rss_scope' => 'benchmark_runner_process'
    }
    performance = {
      'wall_time_seconds' => 1.0,
      'process_rss_kb' => 10_000,
      'rss_kind' => environment['rss_kind'],
      'rss_scope' => environment['rss_scope']
    }.merge(current_performance)
    {
      config: config,
      baseline_reports: { 'sample' => baseline },
      current_reports: { 'sample' => current },
      current_summary: { 'corpora' => [{ 'id' => 'sample', 'performance' => performance }] },
      labels: labels,
      reviews: reviews,
      baseline_performance: {
        'schema_version' => 1,
        'git_ref' => 'baseline',
        'environment' => environment.dup,
        'corpora' => { 'sample' => { 'wall_time_seconds' => 1.0, 'rss_kb' => 10_000 } }
      },
      adversarial_results: adversarial || [{ 'name' => 'spec', 'passed' => true }],
      current_provenance: { 'schema_version' => 1, 'environment' => environment.dup }
    }
  end

  it 'classifies added, removed, state-changed, and confidence-changed candidates' do
    baseline = report(finding('removed'), finding('changed'), finding('confidence'))
    current = report(
      finding('added'),
      finding('changed', state: 'blocked', confidence: 'low'),
      finding('confidence', confidence: 'low')
    )

    audit = described_class.new(audit_inputs(baseline: baseline, current: current)).call
    comparison = audit.dig('corpora', 'sample')

    expect(comparison['added'].map { |change| change['id'] }).to eq(['added'])
    expect(comparison['removed'].map { |change| change['id'] }).to eq(['removed'])
    expect(comparison['state_changed'].map { |change| change['id'] }).to eq(['changed'])
    expect(comparison['confidence_changed'].map { |change| change['id'] }).to eq(%w[changed confidence])
  end

  it 'requires reviewed labels for every newly-high candidate and rejects confirmed false positives' do
    baseline = report(finding('raised', confidence: 'medium'))
    current = report(finding('raised', confidence: 'high'))
    missing = described_class.new(audit_inputs(baseline: baseline, current: current)).call
    label = { 'value' => 'alive', 'rationale' => 'called externally', 'reviewer' => 'maintainer' }
    labeled = described_class.new(
      audit_inputs(baseline: baseline, current: current, labels: { %w[sample raised] => label })
    ).call

    expect(missing.dig('gates', 'new_high_reviewed', 'passed')).to eq(false)
    expect(labeled.dig('gates', 'new_high_reviewed', 'passed')).to eq(true)
    expect(labeled.dig('gates', 'new_high_false_positives', 'passed')).to eq(false)
  end

  it 'reports zero label failures when every newly-high candidate has a valid dead label' do
    baseline = report(finding('raised', confidence: 'medium'))
    current = report(finding('raised', confidence: 'high'))
    label = { 'value' => 'dead', 'rationale' => 'reviewed dead code', 'reviewer' => 'maintainer' }

    audit = described_class.new(
      audit_inputs(baseline: baseline, current: current, labels: { %w[sample raised] => label })
    ).call

    expect(audit.dig('gates', 'new_high_reviewed')).to eq('passed' => true, 'failures' => 0)
  end

  it 'enforces relative and absolute performance budgets' do
    inputs = audit_inputs(
      baseline: report,
      current: report,
      current_performance: { 'wall_time_seconds' => 4.0, 'process_rss_kb' => 19_000 }
    )

    audit = described_class.new(inputs).call

    expect(audit.dig('performance', 'sample')).to include(
      'wall_time_limit_seconds' => 1.5,
      'rss_limit_kb' => 12_500,
      'passed' => false
    )
    expect(audit.dig('gates', 'performance', 'passed')).to eq(false)
  end

  it 'selects deterministic stratified reviews and records zero-difference corpora' do
    baseline = report(finding('Beta'), finding('Alpha'))
    current = report(finding('Beta', state: 'blocked'), finding('Alpha', state: 'blocked'))
    inputs = audit_inputs(baseline: baseline, current: current)
    inputs[:config]['review']['corpora'] = {
      'sample' => { 'strategy' => 'stratified', 'minimum_per_stratum' => 1 }
    }
    inputs[:reviews] = [{
      'corpus' => 'sample',
      'change_type' => 'state_changed',
      'id' => 'Alpha',
      'outcome' => 'expected_safety_change',
      'rationale' => 'blocked is conservative',
      'reviewer' => 'maintainer'
    }]

    audit = described_class.new(inputs).call

    expect(audit.dig('review', 'required').map { |item| item['id'] }).to eq(['Alpha'])
    expect(audit.dig('review', 'coverage', 'sample')).to include(
      'changes' => 2,
      'required' => 1,
      'completed' => 1,
      'zero_difference' => false
    )
  end

  it 'rejects unknown review outcomes instead of silently completing the difference gate' do
    baseline = report(finding('changed'))
    current = report(finding('changed', state: 'blocked'))
    inputs = audit_inputs(baseline: baseline, current: current, reviews: [{
                            'corpus' => 'sample',
                            'change_type' => 'state_changed',
                            'id' => 'changed',
                            'outcome' => 'expected_safety_chagne',
                            'rationale' => 'typo must not pass',
                            'reviewer' => 'maintainer'
                          }])

    audit = described_class.new(inputs).call

    expect(audit.dig('review', 'invalid').length).to eq(1)
    expect(audit.dig('gates', 'difference_review')).to eq('passed' => false, 'failures' => 1)
  end

  it 'explicitly records a zero-difference all-review corpus' do
    inputs = audit_inputs(baseline: report, current: report)
    inputs[:config]['review']['corpora'] = { 'sample' => { 'strategy' => 'all' } }

    audit = described_class.new(inputs).call

    expect(audit.dig('review', 'coverage', 'sample')).to eq(
      'strategy' => 'all',
      'changes' => 0,
      'required' => 0,
      'completed' => 0,
      'zero_difference' => true
    )
  end

  it 'fails closed with a diagnostic when RSS is unavailable' do
    inputs = audit_inputs(baseline: report, current: report)
    inputs[:current_summary]['corpora'].first['performance'] = {
      'wall_time_seconds' => 1.0,
      'rss_status' => 'unavailable'
    }

    audit = described_class.new(inputs).call

    expect(audit.dig('performance', 'sample')).to include(
      'available' => false,
      'passed' => false,
      'diagnostic' => 'current RSS measurement unavailable'
    )
  end

  it 'fails closed when performance provenance does not match the baseline' do
    inputs = audit_inputs(baseline: report, current: report)
    inputs[:current_provenance]['environment']['os'] = 'different-os'

    audit = described_class.new(inputs).call

    expect(audit.dig('performance', 'sample')).to include(
      'available' => false,
      'passed' => false,
      'diagnostic' => 'performance environment mismatch for os'
    )
  end

  it 'rejects vacuous release policies' do
    config = { 'schema_version' => 1, 'corpora' => [], 'review' => { 'corpora' => {} },
               'adversarial_suites' => {} }

    expect do
      described_class::ConfigValidator.new(config, strict_release: false).validate!
    end.to raise_error(Necropsy::Error, /corpora must not be empty/)
  end

  it 'validates the exact five-corpus release policy' do
    path = File.expand_path('../../../bench/audits/0.2.1/config.yml', __dir__)
    config = YAML.safe_load_file(path, aliases: false)

    expect(described_class::ConfigValidator.new(config).validate!).to equal(config)
  end

  it 'rejects skipped benchmark metadata after the audited Git revision changes' do
    Dir.mktmpdir('necropsy-audit-provenance') do |root|
      manifest = File.join(root, 'manifest.yml')
      config = File.join(root, 'audit.yml')
      File.write(manifest, "schema_version: 1\n")
      File.write(config, "schema_version: 1\n")
      run_git(root, 'init')
      run_git(root, 'add', 'manifest.yml', 'audit.yml')
      run_git(root, '-c', 'user.name=Audit Spec', '-c', 'user.email=audit@example.test', 'commit', '-m', 'seed')
      Dir.mktmpdir('necropsy-audit-output') do |output|
        FileUtils.mkdir_p(File.join(output, 'reports'))
        summary = { 'corpora' => [] }
        File.write(File.join(output, 'summary.json'), JSON.generate(summary))
        File.write(File.join(output, 'reports', 'sample.json'), '{}')
        provenance = described_class::RunProvenance.new(
          root: root,
          manifest_path: manifest,
          config_path: config,
          output_dir: output,
          command: 'spec-command'
        )

        Tempfile.create('necropsy-run-metadata') do |file|
          provenance.write(file.path, provenance.complete(provenance.capture_source!, summary))
          expect(provenance.load_and_validate!(file.path)).to include('clean' => true)
          File.write(File.join(output, 'reports', 'sample.json'), '{"stale":true}')
          expect { provenance.load_and_validate!(file.path) }
            .to raise_error(Necropsy::Error, /artifacts/)
          File.write(File.join(output, 'reports', 'sample.json'), '{}')
          File.write(File.join(root, 'new-file'), "changed revision\n")
          run_git(root, 'add', 'new-file')
          run_git(root, '-c', 'user.name=Audit Spec', '-c', 'user.email=audit@example.test',
                  'commit', '-m', 'next')

          expect { provenance.load_and_validate!(file.path) }
            .to raise_error(Necropsy::Error, /git_ref/)
        end
      end
    end
  end

  it 'writes machine-readable and concise human artifacts' do
    audit = described_class.new(audit_inputs(baseline: report, current: report)).call

    with_project do |root|
      paths = described_class::ArtifactWriter.new(audit: audit, output_dir: root).call

      expect(JSON.parse(File.read(paths.fetch(:json)))).to include('schema_version' => 1, 'status' => 'pass')
      expect(File.read(paths.fetch(:markdown))).to include(
        '# 0.2.1 safety release audit', 'Candidate changes', 'Performance', 'Adversarial suites', 'Release gates'
      )
    end
  end

  it 'records adversarial command status and a bounded result summary' do
    suites = {
      'passing' => { 'command' => [RbConfig.ruby, '-e', 'puts "1 example, 0 failures"'] },
      'failing' => { 'command' => [RbConfig.ruby, '-e', 'exit 3'] }
    }

    results = described_class::AdversarialRunner.new(root: Dir.pwd, suites: suites).call.to_h do |result|
      [result.fetch('name'), result]
    end

    expect(results.fetch('passing')).to include('passed' => true, 'summary' => '1 example, 0 failures')
    expect(results.fetch('failing')).to include('passed' => false, 'exit_status' => 3)
  end

  it 'loads the exact integrity-bound baseline from Git' do
    snapshot = described_class::GitSnapshot.new(
      root: File.expand_path('../../..', __dir__),
      git_ref: '51d490188ae9ad846b4c023f14e252ec624a2d5e',
      reports_path: 'bench/golden/v1/reports'
    )

    expect(snapshot.reports(['plain_ruby']).dig('plain_ruby', 'corpus')).to eq('plain_ruby')
  end

  def run_git(root, *arguments)
    output, status = Open3.capture2e('git', *arguments, chdir: root)
    raise output unless status.success?
  end
end
