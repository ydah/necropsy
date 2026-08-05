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
        expect(configuration.world).to eq(:application)
        expect(configuration.load_roots).to eq(:known)
        expect(configuration.dynamic_config(:coverage)).to eq({})
        expect(configuration.fail_on).to eq(:high)
        expect(configuration.baseline_path).to eq('.necropsy_baseline.yml')
        expect(configuration.cache_enabled?).to eq(true)
        expect(configuration.factory_methods).to include('build', 'create', 'build_stubbed')
        expect(configuration.rta_pruning).to eq(:rank_only)
        expect(configuration.ambiguity_limit).to eq(4)
        expect(configuration.quarantine_expiry).to eq(:warn)
        expect(configuration.cache_path).to eq('.necropsy_cache/scan.json')
        expect(configuration.include_paths).to eq([])
        expect(configuration.exclude_paths).to eq([])
        expect(configuration.report_include_paths).to eq([])
        expect(configuration.report_exclude_paths).to eq([])
        expect(configuration.implicit_callers).to eq([])
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
          analysis: { world: :library, load_roots: :all },
          entry_points: { extra: ['Company::*'] },
          ci: { baseline: 'tmp/baseline.yml', fail_on: 'medium' },
          quarantine: { days: 7 },
          bench: { precision_threshold: 0.9, recall_threshold: 0.8 },
          cache: { enabled: false, path: 'tmp/cache.yml' },
          rta: { factory_methods: ['spawn'], pruning: 'legacy' },
          resolution: { ambiguity_limit: 4 },
          implicit_callers: [
            { name_pattern: '^on_', owner_ancestors: ['Framework::Base'], reason: 'framework callback' }
          ],
          report: { include: ['app/**'], exclude: ['app/legacy/**'] }
        }
      end

      it 'normalizes keys and exposes configured thresholds' do
        expect(configuration.static_analyzers).to eq(['name_resolution'])
        expect(configuration.world).to eq(:library)
        expect(configuration).to be_library_world
        expect(configuration.load_roots).to eq(:all)
        expect(configuration.dynamic_config(:coverage)).to include('source' => 'coverage.yml')
        expect(configuration.custom_analyzers).to eq(['Company::Analyzer'])
        expect(configuration.entry_point_patterns).to eq(['Company::*'])
        expect(configuration.fail_on).to eq(:medium)
        expect(configuration.baseline_path).to eq('tmp/baseline.yml')
        expect(configuration.min_observation_days).to eq(14)
        expect(configuration.quarantine_days).to eq(7)
        expect(configuration.quarantine_expiry).to eq(:warn)
        expect(configuration.bench_precision_threshold).to eq(0.9)
        expect(configuration.bench_recall_threshold).to eq(0.8)
        expect(configuration.cache_enabled?).to eq(false)
        expect(configuration.cache_path).to eq('tmp/cache.yml')
        expect(configuration.factory_methods).to eq(['spawn'])
        expect(configuration.rta_pruning).to eq(:legacy)
        expect(configuration.ambiguity_limit).to eq(4)
        expect(configuration.implicit_callers.first).to include(
          name_pattern: /^on_/,
          owner_ancestors: ['Framework::Base'],
          reason: 'framework callback'
        )
        expect(configuration.report_include_paths).to eq(['app/**'])
        expect(configuration.report_exclude_paths).to eq(['app/legacy/**'])
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

    context 'with an invalid world mode' do
      let(:config_data) { { analysis: { world: 'monorepo' } } }

      it 'rejects the value' do
        expect { configuration }.to raise_error(Necropsy::Error, /analysis\.world/)
      end
    end

    context 'with an invalid load-root policy' do
      let(:config_data) { { analysis: { load_roots: 'guessed' } } }

      it 'rejects the value' do
        expect { configuration }.to raise_error(Necropsy::Error, /analysis\.load_roots/)
      end
    end

    context 'with remote dynamic input limits' do
      let(:config_data) do
        {
          analyzers: {
            dynamic: {
              coverband: {
                source: 'rediss://redis.example/0',
                connect_timeout: 1.0,
                read_timeout: 2.0,
                total_timeout: 3.0,
                max_response_bytes: 1024,
                max_bulk_bytes: 512,
                max_array_elements: 100,
                max_resp_depth: 4,
                max_keys: 20,
                max_payload_depth: 8
              }
            }
          }
        }
      end

      it 'accepts finite positive timeout and size limits' do
        expect(configuration.dynamic_config(:coverband)).to include(
          'total_timeout' => 3.0,
          'max_response_bytes' => 1024,
          'max_payload_depth' => 8
        )
      end
    end

    context 'with an invalid remote dynamic input limit' do
      let(:config_data) do
        { analyzers: { dynamic: { coverband: { source: 'redis://localhost', max_keys: 0 } } } }
      end

      it 'rejects non-positive values' do
        expect { configuration }.to raise_error(Necropsy::Error, /coverband\.max_keys must be a finite positive number/)
      end
    end

    context 'with an unbounded remote timeout' do
      let(:config_data) do
        { analyzers: { dynamic: { coverband: { source: 'redis://localhost', total_timeout: Float::INFINITY } } } }
      end

      it 'rejects non-finite values' do
        expect { configuration }.to raise_error(Necropsy::Error, /coverband\.total_timeout must be a finite positive number/)
      end
    end

    context 'with an invalid RTA pruning mode' do
      let(:config_data) { { rta: { pruning: 'aggressive' } } }

      it 'rejects the value' do
        expect { configuration }.to raise_error(
          Necropsy::Error,
          'rta.pruning must be one of: rank_only, legacy'
        )
      end
    end

    context 'with quarantine expiry policy' do
      let(:config_data) { { quarantine: { expiry: 'fail' } } }

      it 'exposes the configured CI behavior' do
        expect(configuration.quarantine_expiry).to eq(:fail)
      end
    end

    context 'with an invalid quarantine expiry policy' do
      let(:config_data) { { quarantine: { expiry: 'raise_score' } } }

      it 'rejects the value' do
        expect { configuration }.to raise_error(
          Necropsy::Error,
          'quarantine.expiry must be one of: warn, fail, ignore'
        )
      end
    end

    context 'with an invalid implicit caller pattern' do
      let(:config_data) { { implicit_callers: [{ name_pattern: '[' }] } }

      it 'rejects the pattern' do
        expect { configuration }.to raise_error(Necropsy::Error, /Invalid implicit caller name_pattern/)
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
