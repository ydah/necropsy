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
        expect(configuration.fail_on).to eq(:new_review_candidate)
        expect(configuration.fail_on_actionability?).to be(true)
        expect(configuration.baseline_path).to eq('.necropsy_baseline.yml')
        expect(configuration.cache_enabled?).to eq(true)
        expect(configuration.factory_methods).to include('build', 'create', 'build_stubbed')
        expect(configuration.rta_pruning).to eq(:rank_only)
        expect(configuration.ambiguity_limit).to eq(4)
        expect(configuration.quarantine_expiry).to eq(:warn)
        expect(configuration.cache_path).to eq('.necropsy_cache/scan.json')
        expect(configuration.include_paths).to eq([])
        expect(configuration.analyze_paths).to eq([])
        expect(configuration.reference_paths).to eq(['**/*'])
        expect(configuration.test_paths).to eq(%w[spec/** test/**])
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
            custom: [{ class: 'Company::Analyzer', trusted: true }]
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
          paths: { analyze: ['lib/**'], reference: ['**/*'], test: ['features/**'] },
          report: { include: ['app/**'], exclude: ['app/legacy/**'] }
        }
      end

      it 'normalizes keys and exposes configured thresholds' do
        expect(configuration.static_analyzers).to eq(['name_resolution'])
        expect(configuration.world).to eq(:library)
        expect(configuration).to be_library_world
        expect(configuration.load_roots).to eq(:all)
        expect(configuration.dynamic_config(:coverage)).to include('source' => 'coverage.yml')
        expect(configuration.custom_analyzers).to eq([{ 'class' => 'Company::Analyzer', 'trusted' => true }])
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
        expect(configuration.analyze_paths).to eq(['lib/**'])
        expect(configuration.include_paths).to eq(['lib/**'])
        expect(configuration.reference_paths).to eq(['**/*'])
        expect(configuration.test_paths).to eq(['features/**'])
        expect(configuration.report_include_paths).to eq(['app/**'])
        expect(configuration.report_exclude_paths).to eq(['app/legacy/**'])
      end
    end

    context 'with legacy include paths' do
      let(:config_data) { { paths: { include: ['app/**'], exclude: ['app/generated/**'] } } }

      it 'uses include as an analyze-scope compatibility alias' do
        expect(configuration.analyze_paths).to eq(['app/**'])
        expect(configuration.include_paths).to eq(['app/**'])
        expect(configuration).to be_legacy_include_paths
        expect(configuration.reference_paths).to eq(['**/*'])
      end
    end

    context 'with Rails auto-detection' do
      let(:files) { { 'Gemfile.lock' => "    rails (8.0.0)\n", 'lib/example.rb' => '' } }

      it 'detects Rails from a safely inventoried Gemfile by default' do
        expect(configuration).to be_rails_enabled
      end

      context 'when the Gemfile is outside the reference scope' do
        let(:config_data) { { paths: { reference: ['lib/**'] } } }

        it 'does not enable Rails heuristics' do
          expect(configuration).not_to be_rails_enabled
        end
      end
    end

    context 'with non-Rails framework dependencies' do
      let(:files) do
        {
          'Gemfile.lock' => "    rubocop (1.80.0)\n    sidekiq (8.0.0)\n",
          'lib/example.rb' => ''
        }
      end

      it 'detects statically supported frameworks from dependency artifacts' do
        expect(configuration.frameworks).to include('rubocop', 'sidekiq')
      end

      it 'does not enable a framework from comments or arbitrary strings' do
        root = create_project(files: {
                                'Gemfile' => <<~RUBY,
                                  # gem "rubocop" is intentionally absent
                                  NOTICE = "sidekiq is not a dependency"
                                  gem "rake"
                                RUBY
                                'lib/example.rb' => ''
                              })

        expect(described_class.load(root: root).frameworks).not_to include('rubocop', 'sidekiq')
      end

      it 'reads literal gem DSL calls without executing the manifest' do
        root = create_project(files: {
                                'Gemfile' => "gem 'rubocop'\ngem dependency_name\n",
                                'lib/example.rb' => ''
                              })

        expect(described_class.load(root: root).frameworks).to include('rubocop')
      end
    end

    it 'does not auto-detect Rails through a Gemfile.lock symlink outside the repository' do
      Dir.mktmpdir do |outside|
        outside_gemfile = File.join(outside, 'Gemfile.lock')
        File.write(outside_gemfile, "    rails (8.0.0)\n")
        root = create_project
        File.symlink(outside_gemfile, File.join(root, 'Gemfile.lock'))

        expect(described_class.load(root: root)).not_to be_rails_enabled
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

    context 'with invalid bounded numeric settings' do
      it 'rejects thresholds outside the unit interval' do
        [Float::INFINITY, -0.1, 1.1, 'not-a-number'].each do |value|
          root = create_project(config: { bench: { precision_threshold: value } })
          expect { described_class.load(root: root) }.to raise_error(Necropsy::Error, /Numeric|between 0 and 1/)
        end
      end

      it 'rejects non-positive and fractional day counts' do
        [0, -1, 1.5, '2.5'].each do |value|
          root = create_project(config: { quarantine: { days: value } })
          expect { described_class.load(root: root) }.to raise_error(Necropsy::Error, /positive integer|Numeric/)
        end
      end
    end

    context 'with invalid static analyzer composition' do
      it 'rejects duplicates and dependency-order inversions' do
        duplicate = create_project(config: { analyzers: { static: %w[name_resolution name_resolution] } })
        inverted = create_project(config: { analyzers: { static: %w[rta name_resolution] } })

        expect { described_class.load(root: duplicate) }.to raise_error(Necropsy::Error, /Duplicate static analyzers/)
        expect { described_class.load(root: inverted) }.to raise_error(Necropsy::Error, /dependency order/)
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

    context 'with a custom analyzer lacking an explicit trust declaration' do
      let(:config_data) { { analyzers: { custom: [{ class: 'Company::Analyzer' }] } } }

      it 'rejects in-process execution' do
        expect { configuration }.to raise_error(Necropsy::Error, /requires trusted: true/)
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
