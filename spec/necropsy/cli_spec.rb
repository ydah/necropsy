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

    context 'with informational flags' do
      it 'returns normally for help and version' do
        expect { described_class.run(['--help']) }.to output(/Usage: necropsy/).to_stdout
        expect { described_class.run(['--version']) }.to output("#{Necropsy::VERSION}\n").to_stdout
      end
    end
  end
end
