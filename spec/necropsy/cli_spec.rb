# frozen_string_literal: true

require 'necropsy/cli'

class CliFailingAnalyzer < Necropsy::Analyzer
  def analyze(*)
    raise 'intentional analyzer failure'
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :cli_failing, kind: :static, soundness: :partial, description: 'fails for CLI health specs'
    )
  end
end

class CliDegradedAnalyzer < Necropsy::Analyzer
  def analyze(*)
    Necropsy::AnalyzerResult.new(
      edge_evidences: [],
      alive_evidences: [],
      uncertainties: {},
      observation: {},
      blockers: [
        Necropsy::Blocker.new(
          kind: :reference_scan_incomplete,
          scope_kind: :global,
          scope_value: '*',
          source: :cli_degraded,
          reason: 'fixture reference scan is incomplete',
          metadata: { 'caller_domain' => 'runtime' }
        )
      ]
    )
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :cli_degraded, kind: :static, soundness: :conservative, description: 'degraded CLI fixture'
    )
  end
end

class CliInvalidResultAnalyzer < Necropsy::Analyzer
  def analyze(graph, _project)
    caller, callee = graph.method_nodes.first(2)
    edge = Necropsy::EdgeEvidence.new(
      caller_id: caller.graph_id,
      callee_id: callee.graph_id,
      evidence: evidence(kind: :call_edge, details: 'staged before invalid result', relation: :call_edge)
    )
    Necropsy::AnalyzerResult.empty.with(edge_evidences: [edge], uncertainties: 1)
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :cli_invalid_result, kind: :static, soundness: :conservative, description: 'invalid result fixture'
    )
  end
end

class CliUnprovenResolutionAnalyzer < Necropsy::Analyzer
  def analyze(graph, _project)
    site = graph.call_sites.fetch(0)
    record = Necropsy::ResolutionRecord.new(
      resolution: Necropsy::Resolution.new(
        call_site_id: site.call_site_id, target_definition_ids: [], status: :complete
      ),
      producer: :cli_unproven,
      producer_version: '1'
    )
    Necropsy::AnalyzerResult.empty.with(resolutions: [record])
  end

  def profile
    Necropsy::AnalyzerProfile.new(
      name: :cli_unproven, kind: :static, soundness: :partial, description: 'unproven resolution fixture'
    )
  end
end

RSpec.describe Necropsy::CLI do
  describe 'semantics' do
    it 'emits the generated matrix without requiring a project' do
      payload = nil
      expect do
        result = described_class.run(['semantics', '--format', 'json'])
        expect(result).to eq(0)
      end.to output(satisfy do |text|
        payload = JSON.parse(text)
        payload.fetch('schema_version') == Necropsy::SemanticsMatrix::SCHEMA_VERSION
      end).to_stdout
      expect(payload.fetch('prism_nodes')).not_to be_empty
    end
  end

  describe 'artifact run identity' do
    it 'is injectable and deterministic under SOURCE_DATE_EPOCH' do
      options = { root: '/project', as_of: nil }
      injected = described_class.new(run_id_generator: -> { 'injected-run' })
      reproducible = described_class.new(environment: { 'SOURCE_DATE_EPOCH' => '1' })

      expect(injected.send(:artifact_run_id, options, '/tmp/output.yml', 'coverage')).to eq('injected-run')
      expect(reproducible.send(:artifact_run_id, options, '/tmp/output.yml', 'coverage')).to eq(
        reproducible.send(:artifact_run_id, options, '/tmp/output.yml', 'coverage')
      )
    end
  end

  describe '.run' do
    subject(:status) { described_class.run(argv) }

    context 'with an unknown command' do
      let(:argv) { ['unknown'] }

      it 'prints usage context and returns an error status' do
        expect { status }.to output(/Unknown command: unknown/).to_stderr
        expect(status).to eq(2)
      end
    end

    context 'with baseline and check commands' do
      let(:project_root) { create_project(files: { 'app/sample.rb' => 'class CliSample; def dead; end; end' }) }
      let(:baseline_path) { File.join(project_root, '.necropsy_baseline.yml') }

      it 'writes a baseline and passes check against it' do
        baseline_status = nil
        check_status = nil

        expect do
          baseline_status = described_class.run(['baseline', '--root', project_root, '--baseline', baseline_path])
        end.to output(/Wrote #{Regexp.escape(baseline_path)}/).to_stdout
        expect do
          check_status = described_class.run(['check', '--root', project_root, '--baseline', baseline_path])
        end.to output("Necropsy check passed\n").to_stdout

        expect(baseline_status).to eq(0)
        expect(check_status).to eq(0)
      end

      it 'renders check failures in the requested machine-readable format' do
        result = nil
        valid_failure_report = satisfy do |rendered|
          payload = JSON.parse(rendered)
          expect(payload.fetch('findings')).to contain_exactly(
            include('node' => include('symbol_id' => 'CliSample#dead'))
          )
          expect(payload.fetch('analysis_health')).to include('status' => 'complete')
          expect(payload).to include('source_snapshot', 'artifact_provenance', 'graph')
        end

        expect do
          result = described_class.run([
                                         'check', '--root', project_root, '--baseline', baseline_path,
                                         '--fail-on', 'low', '--format', 'json', '--include-graph'
                                       ])
        end.to output(valid_failure_report).to_stdout
        expect(result).to eq(1)
      end

      it 'does not let a custom baseline path become a non-Ruby self-reference' do
        custom_path = File.join(project_root, 'reviewed-findings.yml')
        File.write(custom_path, "previous: CliSample#dead\n")

        expect do
          described_class.run(['baseline', '--root', project_root, '--baseline', custom_path])
        end.to output(/Wrote #{Regexp.escape(custom_path)}/).to_stdout

        finding = YAML.load_file(custom_path).fetch('findings').first
        expect(finding).to include(
          'node_id' => 'CliSample#dead',
          'classification' => 'unreachable',
          'confidence' => 'medium'
        )
        expect do
          described_class.run(['check', '--root', project_root, '--baseline', custom_path])
        end.to output("Necropsy check passed\n").to_stdout
      end

      it 'fails closed with a review report for an ambiguous v1 logical baseline' do
        repeated_root = create_project(files: {
                                         'app/repeated.rb' => <<~RUBY
                                           class CliRepeated
                                             def dead
                                             end

                                             def dead
                                               :replacement
                                             end
                                           end
                                         RUBY
                                       })
        repeated_baseline = File.join(repeated_root, '.necropsy_baseline.yml')
        logical_fingerprint = Digest::SHA256.hexdigest('unreachable:CliRepeated#dead')
        File.write(repeated_baseline, {
          'version' => 1,
          'findings' => [{
            'fingerprint' => logical_fingerprint,
            'node_id' => 'CliRepeated#dead',
            'file' => 'app/repeated.rb'
          }]
        }.to_yaml)

        result = nil
        expect do
          result = described_class.run([
                                         'check', '--root', repeated_root, '--baseline', repeated_baseline,
                                         '--fail-on', 'low'
                                       ])
        end.to output(/Baseline migration requires review.*CliRepeated#dead.*legacy_baseline_requires_migration/m).to_stdout
        expect(result).to eq(1)

        expect do
          result = described_class.run([
                                         'check', '--root', repeated_root, '--baseline', repeated_baseline,
                                         '--fail-on', 'high'
                                       ])
        end.to output(/Baseline migration requires review.*Ambiguous mappings: 1/m).to_stdout
        expect(result).to eq(1)
      end

      it 'migrates a uniquely matched legacy baseline only through the explicit command' do
        target_report = Necropsy.analyze(root: project_root)
        target = target_report.actionable_candidates.first
        File.write(baseline_path, {
          'version' => 1,
          'findings' => [{
            'fingerprint' => target.logical_fingerprint,
            'classification' => target.classification.to_s,
            'node_id' => target.node.symbol_id,
            'file' => target.node.file
          }]
        }.to_yaml)

        expect do
          result = described_class.run(['check', '--root', project_root, '--baseline', baseline_path])
          expect(result).to eq(1)
        end.to output(/legacy_baseline_requires_migration/).to_stdout
        expect do
          result = described_class.run(['baseline', 'migrate', '--root', project_root, '--baseline', baseline_path])
          expect(result).to eq(0)
        end.to output(/Migrated #{Regexp.escape(baseline_path)}/).to_stdout
        expect(YAML.load_file(baseline_path)).to include('schema_version' => 2)
      end
    end

    context 'with an unhealthy analysis' do
      let(:project_root) do
        create_project(
          files: { 'app/sample.rb' => 'class CliHealth; def dead; end; end' },
          config: { analyzers: { static: [], custom: [{ class: 'CliFailingAnalyzer', trusted: true }] } }
        )
      end
      let(:baseline_path) { File.join(project_root, '.necropsy_baseline.yml') }

      it 'continues analyze but fails check on analyzer failure' do
        analyze_status = nil
        check_status = nil

        expect do
          analyze_status = described_class.run(['analyze', '--root', project_root])
        end.to output(/Analysis health: invalid/).to_stdout
        expect do
          check_status = described_class.run(['check', '--root', project_root, '--baseline', baseline_path])
        end.to output(/Analysis health: invalid.*analyzer_failure/m).to_stdout

        expect(analyze_status).to eq(0)
        expect(check_status).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
      end

      it 'makes analyze health failure explicit in strict mode and never allows invalid reasons' do
        strict_status = nil
        allowed_status = nil

        expect do
          strict_status = described_class.run(['analyze', '--strict-health', '--root', project_root])
        end.to output(/Analysis health: invalid/).to_stdout
        expect do
          allowed_status = described_class.run([
                                                 'analyze', '--strict-health',
                                                 '--allow-degraded=analyzer_failure', '--root', project_root
                                               ])
        end.to output(/Analysis health: invalid/).to_stdout

        expect(strict_status).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
        expect(allowed_status).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
      end

      it 'does not write a baseline from incomplete analysis' do
        result = nil

        expect do
          result = described_class.run(['baseline', '--root', project_root, '--baseline', baseline_path])
        end.to output(/Analysis health: invalid.*analyzer_failure/m).to_stdout

        expect(result).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
        expect(File).not_to exist(baseline_path)
      end

      it 'preserves the requested machine-readable format on a health failure' do
        payload = nil
        result = nil

        expect do
          result = described_class.run([
                                         'check', '--format', 'json', '--root', project_root,
                                         '--baseline', baseline_path
                                       ])
        end.to output(satisfy { |text| payload = JSON.parse(text) }).to_stdout

        expect(result).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
        expect(payload.fetch('analysis_health')).to include(
          'status' => 'invalid',
          'reasons' => include(include('code' => 'analyzer_failure'))
        )
      end

      it 'does not ignore strict health in diagnostics or write quarantine from invalid analysis' do
        expect do
          expect(described_class.run(['why', 'CliHealth#dead', '--strict-health', '--root', project_root])).to eq(
            Necropsy::CLI::HEALTH_FAILURE_STATUS
          )
        end.to output(/Analysis health: invalid.*analyzer_failure/m).to_stdout
        expect do
          expect(described_class.run(['quarantine', '--write', '--root', project_root])).to eq(
            Necropsy::CLI::HEALTH_FAILURE_STATUS
          )
        end.to output(/Analysis health: invalid.*analyzer_failure/m).to_stdout
        expect(File.read(File.join(project_root, 'app/sample.rb'))).not_to include('necropsy:quarantine')
      end
    end

    context 'with explicitly allowed degraded analysis' do
      let(:project_root) do
        create_project(
          files: { 'app/sample.rb' => 'class CliDegraded; def dead; end; end' },
          config: { analyzers: { static: [], custom: [{ class: 'CliDegradedAnalyzer', trusted: true }] } }
        )
      end
      let(:baseline_path) { File.join(project_root, '.necropsy_baseline.yml') }

      it 'requires the exact degraded reason in strict analyze and check workflows' do
        expect do
          expect(described_class.run(['analyze', '--strict-health', '--root', project_root])).to eq(
            Necropsy::CLI::HEALTH_FAILURE_STATUS
          )
        end.to output(/Analysis health: degraded/).to_stdout

        allow_option = '--allow-degraded=reference_scan_incomplete'
        expect do
          expect(described_class.run([
                                       'analyze', '--strict-health', allow_option, '--root', project_root
                                     ])).to eq(0)
        end.to output(/Analysis health: degraded/).to_stdout
        expect do
          expect(described_class.run([
                                       'baseline', allow_option, '--root', project_root,
                                       '--baseline', baseline_path
                                     ])).to eq(0)
        end.to output(/Wrote/).to_stdout
        expect do
          expect(described_class.run([
                                       'check', allow_option, '--root', project_root,
                                       '--baseline', baseline_path
                                     ])).to eq(0)
        end.to output("Necropsy check passed\n").to_stdout
      end
    end

    context 'with invalid analyzer result stages' do
      it 'fails check for capability validation and atomic apply failures' do
        {
          'CliInvalidResultAnalyzer' => /NoMethodError/,
          'CliUnprovenResolutionAnalyzer' => /complete_resolution capability/
        }.each do |analyzer_name, reason|
          root = create_project(
            files: {
              'app/sample.rb' => 'class CliAnalyzerTarget; def run = helper; def helper = :ok; end'
            },
            config: { analyzers: { static: [], custom: [{ class: analyzer_name, trusted: true }] } }
          )
          status = nil

          expect do
            status = described_class.run(['check', '--root', root])
          end.to output(/Analysis health: invalid.*#{reason}/m).to_stdout
          expect(status).to eq(Necropsy::CLI::HEALTH_FAILURE_STATUS)
          report = Necropsy::Runner.new(root: root).analyze
          expect(report.graph.edges).to be_empty if analyzer_name == 'CliInvalidResultAnalyzer'
        end
      end
    end

    context 'with a gold standard relative to the process directory' do
      let(:project_root) do
        create_project(files: {
                         'app/bench_sample.rb' => 'class CliBenchSample; def measured_dead; end; end',
                         'reviewed.yml' => "dead_methods:\n  - CliBenchSample#measured_dead\n"
                       })
      end

      it 'uses the same absolute path for evaluation and reference exclusion' do
        status = nil
        parent = File.dirname(project_root)
        root_argument = File.basename(project_root)
        gold_argument = File.join(root_argument, 'reviewed.yml')

        expect do
          Dir.chdir(parent) do
            status = described_class.run([
                                           'bench', '--root', root_argument,
                                           '--gold-standard', gold_argument,
                                           '--min-confidence', 'low'
                                         ])
          end
        end.to output(/"recall": 1\.0/).to_stdout
        expect(status).to eq(0)
      end

      it 'returns nonzero for failed release criteria only when --check is requested' do
        failed_gold = File.join(project_root, 'failed-gold.yml')
        File.write(failed_gold, "dead_methods:\n  - Missing#candidate\n")

        unchecked = nil
        checked = nil
        expect do
          unchecked = described_class.run([
                                            'bench', '--root', project_root, '--gold-standard', failed_gold,
                                            '--min-confidence', 'low'
                                          ])
        end.to output(/"passed": false/).to_stdout
        expect do
          checked = described_class.run([
                                          'bench', '--check', '--root', project_root, '--gold-standard', failed_gold,
                                          '--min-confidence', 'low'
                                        ])
        end.to output(/"passed": false/).to_stdout

        expect(unchecked).to eq(0)
        expect(checked).to eq(1)
      end
    end

    context 'with an expired quarantine annotation' do
      let(:project_root) do
        create_project(
          files: {
            'app/sample.rb' => <<~RUBY
              class CliQuarantine
                # necropsy:quarantine since=2000-01-01
                def dead
                end
              end
            RUBY
          },
          config: { quarantine: { expiry: expiry_policy } }
        )
      end

      context 'when expiry warns' do
        let(:expiry_policy) { 'warn' }

        it 'reports the review and lets check pass' do
          result = nil
          expect do
            result = described_class.run(['check', '--root', project_root])
          end.to output("Necropsy check passed\n").to_stdout.and output(/Quarantine expiry warning/).to_stderr
          expect(result).to eq(0)
        end
      end

      context 'when expiry fails' do
        let(:expiry_policy) { 'fail' }

        it 'fails check without changing analysis confidence' do
          result = nil
          expect do
            result = described_class.run(['check', '--root', project_root])
          end.to output(/Quarantine expiry failed/).to_stdout.and output('').to_stderr
          expect(result).to eq(1)
        end
      end

      context 'when expiry is ignored' do
        let(:expiry_policy) { 'ignore' }

        it 'does not report or fail the operational check' do
          result = nil
          expect do
            result = described_class.run(['check', '--root', project_root])
          end.to output("Necropsy check passed\n").to_stdout.and output('').to_stderr
          expect(result).to eq(0)
        end
      end
    end

    context 'with an invalid quarantine date' do
      let(:project_root) do
        create_project(
          files: {
            'app/sample.rb' => <<~RUBY
              class CliInvalidQuarantine
                # necropsy:quarantine since=not-a-date
                def dead
                end
              end
            RUBY
          },
          config: { quarantine: { expiry: expiry_policy } }
        )
      end

      %w[warn fail ignore].each do |policy|
        context "when expiry policy is #{policy}" do
          let(:expiry_policy) { policy }

          it 'always warns without failing check' do
            result = nil
            expect do
              result = described_class.run(['check', '--root', project_root])
            end.to output("Necropsy check passed\n").to_stdout.and output(
              %r{Invalid quarantine date warning:.*app/sample.rb:3 CliInvalidQuarantine#dead}m
            ).to_stderr
            expect(result).to eq(0)
          end
        end
      end
    end

    context 'with expired and invalid quarantine annotations' do
      let(:project_root) do
        create_project(
          files: {
            'app/sample.rb' => <<~RUBY
              class CliMixedQuarantine
                # necropsy:quarantine since=not-a-date
                def invalid_date
                end

                # necropsy:quarantine since=2000-01-01
                def expired
                end
              end
            RUBY
          },
          config: { quarantine: { expiry: 'fail' } }
        )
      end

      it 'warns for the invalid date and fails only for the required review' do
        result = nil
        expect do
          result = described_class.run(['check', '--root', project_root])
        end.to output(
          %r{Quarantine expiry failed:.*app/sample.rb:7 CliMixedQuarantine#expired}m
        ).to_stdout.and output(
          %r{Invalid quarantine date warning:.*app/sample.rb:3 CliMixedQuarantine#invalid_date}m
        ).to_stderr
        expect(result).to eq(1)
      end
    end

    context 'with bench without a gold standard' do
      let(:project_root) { create_project }
      let(:argv) { ['bench', '--root', project_root] }

      it 'returns a parse error status' do
        expect { status }.to output(/--gold-standard is required/).to_stderr
        expect(status).to eq(2)
      end
    end

    context 'with record for a local Ruby script' do
      let(:project_root) do
        create_project(files: {
                         'runner.rb' => <<~RUBY
                           class CliRecordSample
                             def run
                               :ok
                             end
                           end

                           CliRecordSample.new.run
                         RUBY
                       })
      end
      let(:output_path) { File.join(project_root, 'trace.yml') }
      let(:argv) { ['record', '--root', project_root, '--output', output_path, '--', 'runner.rb'] }
      let(:payload) { YAML.load_file(output_path) }

      it 'records TracePoint output' do
        expect { status }.to output(/Wrote #{Regexp.escape(output_path)}/).to_stdout
        expect(status).to eq(0)
        expect(payload.fetch('nodes')).to include('CliRecordSample#run')
      end
    end

    context 'with invalid output options' do
      let(:project_root) { create_project }

      it 'rejects unknown confidence levels and formats without a stack trace' do
        expect do
          described_class.run(['analyze', '--root', project_root, '--min-confidence', 'maximum'])
        end.to output(/unknown confidence level: maximum/).to_stderr
        expect do
          described_class.run(['analyze', '--root', project_root, '--format', 'xml'])
        end.to output(/invalid argument.*--format/).to_stderr
      end
    end

    context 'with NDJSON graph export' do
      let(:project_root) { create_project(files: { 'app/sample.rb' => 'class CliStream; def dead; end; end' }) }

      it 'streams the report and graph as separate records' do
        output = StringIO.new
        allow($stdout).to receive(:puts) { |line| output.puts(line) }

        expect(described_class.run(['analyze', '--format', 'ndjson', '--root', project_root])).to eq(0)
        records = output.string.lines.map { |line| JSON.parse(line) }
        expect(records.map { |record| record.fetch('record') }).to include('report', 'node', 'graph_metadata')
      end
    end

    context 'with graph self-check' do
      let(:project_root) { create_project(files: { 'app/sample.rb' => 'class CliGraph; def dead; end; end' }) }

      it 'validates graph invariants after analysis' do
        expect do
          expect(described_class.run(['analyze', '--self-check', '--root', project_root])).to eq(0)
        end.to output(/Necropsy report/).to_stdout
      end
    end

    context 'with the default confidence threshold' do
      let(:project_root) do
        create_project(files: { 'app/sample.rb' => 'class CliSample; attr_reader :maybe; end' })
      end

      it 'omits low-confidence findings unless explicitly requested' do
        expect do
          described_class.run(['analyze', '--root', project_root])
        end.to output(/Findings: 0/).to_stdout
        expect do
          described_class.run(['analyze', '--root', project_root, '--min-confidence', 'low'])
        end.to output(/Findings: 1.*CliSample#maybe/m).to_stdout
      end
    end

    context 'with informational flags' do
      it 'returns normally for help and version' do
        expect { described_class.run(['--help']) }.to output(/Usage: necropsy/).to_stdout
        expect { described_class.run(['--version']) }.to output("#{Necropsy::VERSION}\n").to_stdout
      end
    end

    context 'with a reproducible as-of date' do
      let(:project_root) do
        create_project(files: { 'app/sample.rb' => 'class CliClock; def dead; end; end' })
      end

      it 'uses the date in quarantine suggestions and rejects malformed dates' do
        result = nil
        expect do
          result = described_class.run(['quarantine', '--root', project_root, '--as-of', '2000-01-02'])
        end.to output(/necropsy:quarantine since=2000-01-02/).to_stdout
        expect(result).to eq(0)

        expect do
          result = described_class.run(['analyze', '--root', project_root, '--as-of', 'not-a-date'])
        end.to output(/as-of must be an ISO 8601 date/).to_stderr
        expect(result).to eq(2)
      end
    end

    context 'with diagnostic commands' do
      let(:project_root) do
        create_project(files: {
                         'lib/cli_diagnostics.rb' => <<~RUBY,
                           class CliDiagnostics
                             def live
                             end

                             def dead
                             end
                           end
                         RUBY
                         'exe/tool' => <<~RUBY
                           #!/usr/bin/env ruby
                           CliDiagnostics.new.live
                         RUBY
                       })
      end

      it 'shows reachability paths and score explanations' do
        expect do
          described_class.run(['why', 'CliDiagnostics#live', '--root', project_root])
        end.to output(/Alive \(runtime\).*CliDiagnostics#live/m).to_stdout
        expect do
          described_class.run(['explain', 'CliDiagnostics#dead', '--root', project_root])
        end.to output(/CliDiagnostics#dead \[def:v1:[a-f0-9]+\]: unreachable.*base\(unreachable\)/m).to_stdout
      end

      it 'shows refutable why-not diagnostics in human and JSON formats' do
        expect do
          described_class.run(['why-not', 'CliDiagnostics#dead', '--root', project_root])
        end.to output(
          /Why-not \(candidate\): CliDiagnostics#dead.*Incoming call sites examined: 0.*Suggested next evidence:/m
        ).to_stdout

        output = StringIO.new
        allow($stdout).to receive(:puts) { |value| output.puts(value) }
        expect(described_class.run(
                 ['why-not', 'CliDiagnostics#dead', '--root', project_root, '--format', 'json']
               )).to eq(0)
        expect(JSON.parse(output.string)).to include(
          'schema_version' => 'necropsy.why-not.v1', 'state' => 'candidate'
        )
      end

      it 'requires either a logical symbol or physical definition ID' do
        result = nil

        expect { result = described_class.run(['why', '--root', project_root]) }
          .to output(/why requires a symbol or definition ID/).to_stderr
        expect(result).to eq(2)
      end

      it 'lists executable physical-ID commands for an ambiguous symbol' do
        ambiguous_root = create_project(files: {
                                          'lib/first.rb' => "class Repeated\n  def run; end\nend\n",
                                          'lib/second.rb' => "class Repeated\n  def run; end\nend\n"
                                        })

        expect do
          described_class.run(['why', 'Repeated#run', '--root', ambiguous_root])
        end.to output(
          /Ambiguous symbol ID: Repeated#run.*Matched 2 physical definitions:.*why: bundle exec necropsy why def:v1:/m
        ).to_stdout
      end
    end
  end
end
