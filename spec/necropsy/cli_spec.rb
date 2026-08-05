# frozen_string_literal: true

require 'necropsy/cli'

RSpec.describe Necropsy::CLI do
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
        end.to output(
          /Baseline migration requires review.*CliRepeated#dead.*def:v1:.*def:v1:.*Regenerate the baseline/m
        ).to_stdout
        expect(result).to eq(1)

        expect do
          result = described_class.run([
                                         'check', '--root', repeated_root, '--baseline', repeated_baseline,
                                         '--fail-on', 'high'
                                       ])
        end.to output(/Baseline migration requires review.*Ambiguous mappings: 1/m).to_stdout
        expect(result).to eq(1)
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
