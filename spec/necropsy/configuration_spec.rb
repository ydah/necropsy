# frozen_string_literal: true

RSpec.describe Necropsy::Configuration do
  describe '.load' do
    subject(:configuration) { described_class.load(root: project_root) }

    let(:project_root) { create_project(files: files, config: config_data) }
    let(:files) { {} }
    let(:config_data) { nil }

    context 'without a config file' do
      it 'loads defaults' do
        expect(configuration.static_analyzers).to eq(%w[name_resolution cha rta])
        expect(configuration.dynamic_config(:coverage)).to eq({})
        expect(configuration.fail_on).to eq(:high)
        expect(configuration.baseline_path).to eq('.necropsy_baseline.yml')
        expect(configuration.cache_enabled?).to eq(true)
        expect(configuration.factory_methods).to include('build', 'create', 'build_stubbed')
        expect(configuration.ambiguity_limit).to eq(4)
        expect(configuration.cache_path).to eq('.necropsy_cache/scan.json')
        expect(configuration.include_paths).to eq([])
        expect(configuration.exclude_paths).to eq([])
      end
    end

    context 'with YAML configuration' do
      let(:config_data) do
        {
          analyzers: {
            static: %i[name_resolution],
            dynamic: { coverage: { source: 'coverage.yml', min_observation_days: 14 } },
            custom: ['Company::Analyzer']
          },
          entry_points: { extra: ['Company::*'] },
          ci: { baseline: 'tmp/baseline.yml', fail_on: 'medium' },
          quarantine: { days: 7 },
          bench: { precision_threshold: 0.9, recall_threshold: 0.8 },
          cache: { enabled: false, path: 'tmp/cache.yml' },
          rta: { factory_methods: ['spawn'] },
          resolution: { ambiguity_limit: 4 }
        }
      end

      it 'normalizes keys and exposes configured thresholds' do
        expect(configuration.static_analyzers).to eq(['name_resolution'])
        expect(configuration.dynamic_config(:coverage)).to include('source' => 'coverage.yml')
        expect(configuration.custom_analyzers).to eq(['Company::Analyzer'])
        expect(configuration.entry_point_patterns).to eq(['Company::*'])
        expect(configuration.fail_on).to eq(:medium)
        expect(configuration.baseline_path).to eq('tmp/baseline.yml')
        expect(configuration.min_observation_days).to eq(14)
        expect(configuration.quarantine_days).to eq(7)
        expect(configuration.bench_precision_threshold).to eq(0.9)
        expect(configuration.bench_recall_threshold).to eq(0.8)
        expect(configuration.cache_enabled?).to eq(false)
        expect(configuration.cache_path).to eq('tmp/cache.yml')
        expect(configuration.factory_methods).to eq(['spawn'])
        expect(configuration.ambiguity_limit).to eq(4)
      end
    end

    context 'with unlimited ambiguous resolution' do
      let(:config_data) { { resolution: { ambiguity_limit: 'unlimited' } } }

      it 'accepts all same-name fallback candidates' do
        expect(configuration.ambiguity_limit).to eq(Float::INFINITY)
      end
    end

    context 'with an invalid ambiguity limit' do
      let(:config_data) { { resolution: { ambiguity_limit: 0 } } }

      it 'rejects the value' do
        expect { configuration }.to raise_error(Necropsy::Error, /ambiguity_limit/)
      end
    end

    context 'when Rails is configured explicitly' do
      let(:config_data) { { frameworks: ['rails'] } }

      it { is_expected.to be_rails_enabled }
    end

    context 'when Rails is present in Gemfile.lock' do
      let(:files) { { 'Gemfile.lock' => "    rails (7.1.0)\n" } }

      it { is_expected.to be_rails_enabled }
    end

    context 'with YAML aliases' do
      let(:files) do
        {
          '.necropsy.yml' => <<~YAML
            analyzers:
              dynamic:
                coverage: &defaults
                  source: coverage.yml
                trace_point:
                    <<: *defaults
          YAML
        }
      end

      it 'loads the aliased configuration' do
        expect(configuration.dynamic_config(:coverage)).to include('source' => 'coverage.yml')
        expect(configuration.dynamic_config(:trace_point)).to include('source' => 'coverage.yml')
      end
    end

    context 'with malformed YAML' do
      let(:files) { { '.necropsy.yml' => "analyzers: [\n" } }

      it 'raises a domain error with the configuration path' do
        expect { configuration }.to raise_error(Necropsy::Error, /Could not parse configuration/)
      end
    end

    context 'with an unknown option' do
      let(:config_data) { { ci: { fail_onn: 'high' } } }

      it 'rejects configuration typos' do
        expect { configuration }.to raise_error(Necropsy::Error, /Unknown ci option: fail_onn/)
      end
    end
  end
end
