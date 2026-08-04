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
        end.to output(/CliDiagnostics#dead: unreachable.*base\(unreachable\)/m).to_stdout
      end
    end
  end
end
