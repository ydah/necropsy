# frozen_string_literal: true

require 'fileutils'
require 'necropsy/cli'
require 'rbconfig'
require 'socket'

RSpec.describe Necropsy do
  it 'has a version number' do
    expect(Necropsy::VERSION).not_to be nil
  end

  it 'classifies unreachable and test-only methods' do
    report = described_class.analyze(root: fixture_path('sample_project'))
    findings = report.findings.to_h { |finding| [finding.node.id, finding] }

    expect(findings.fetch('Sample::Widget#dead_model').classification).to eq(:unreachable)
    expect(findings.fetch('Sample::Widget#test_only').classification).to eq(:test_only_reachable)
    expect(findings).not_to include('Sample::Widget#render')
    expect(findings).not_to include('Sample::Widget#live_helper')
    expect(findings).not_to include('Sample::Widget#persist_callback')
    expect(findings).not_to include('Sample::BaseWidget#inherited_live')
    expect(findings).not_to include('Sample::Renderable#decorated')
    expect(findings).not_to include('Sample::WidgetsHelper#widget_title')
    expect(findings).not_to include('Sample::WidgetsHelper#component_title')
    expect(findings).not_to include('Sample::TitleComponent#call')
    expect(findings).not_to include('Sample::MountedEngine.call')
    expect(findings).not_to include('Sample::WidgetsController#audit')
    expect(findings).not_to include('Sample::WidgetsController#legacy')
    expect(findings).not_to include('Sample::WidgetsController#contextual')
    expect(findings).not_to include('Sample::WidgetsController#scoped')
    expect(findings).not_to include('Sample::Admin::WidgetsController#index')
    expect(findings).not_to include('Sample::Admin::WidgetsController#preview')
    expect(findings).not_to include('Sample::Admin::WidgetsController#drawn')
  end

  it 'writes and applies a baseline' do
    report = described_class.analyze(root: fixture_path('sample_project'))
    path = File.join(Dir.mktmpdir, '.necropsy_baseline.yml')

    Necropsy::Guardrail::Baseline.write(report, path: path)
    baseline = Necropsy::Guardrail::Baseline.load(path)

    expect(report.findings.all? { |finding| baseline.include?(finding) }).to eq(true)
  end

  it 'evaluates precision and recall against a gold standard' do
    report = described_class.analyze(root: fixture_path('sample_project'))
    result = Necropsy::Bench::Evaluator.new(
      report: report,
      gold_standard_path: fixture_path('sample_project/gold.yml'),
      min_confidence: :low
    ).call

    expect(result['recall']).to eq(1.0)
  end

  it 'persists scan results in the project cache' do
    dir = File.join(Dir.mktmpdir, 'sample_project')
    FileUtils.mkdir_p(dir)
    FileUtils.cp_r(Dir.glob(File.join(fixture_path('sample_project'), '*'), File::FNM_DOTMATCH).reject do |path|
      path.end_with?('/.', '/..')
    end, dir)

    config = Necropsy::Configuration.load(root: dir)
    first = Necropsy::Project.new(root: dir, config: config).scan_result
    second = Necropsy::Project.new(root: dir, config: config).scan_result

    expect(File).to exist(File.join(dir, '.necropsy_cache/scan.yml'))
    expect(second.nodes.map(&:id)).to eq(first.nodes.map(&:id))
  end

  it 'invalidates scan cache when scanner-affecting configuration changes' do
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'app.rb'), <<~RUBY)
      class CacheFactorySample
        def self.spawn
          new
        end
      end

      CacheFactorySample.spawn
    RUBY

    first_config = Necropsy::Configuration.load(root: dir)
    first = Necropsy::Project.new(root: dir, config: first_config).scan_result
    File.write(File.join(dir, '.necropsy.yml'), { 'rta' => { 'factory_methods' => ['spawn'] } }.to_yaml)
    second_config = Necropsy::Configuration.load(root: dir)
    second = Necropsy::Project.new(root: dir, config: second_config).scan_result

    expect(first.instantiated_classes).not_to include('CacheFactorySample')
    expect(second.instantiated_classes).to include('CacheFactorySample')
  end

  it 'classifies statically reachable methods as unused when dynamic evidence is absent' do
    dir = Dir.mktmpdir
    coverage_path = File.join(dir, 'coverage.yml')
    config_path = File.join(dir, '.necropsy.yml')

    File.write(coverage_path, {
      'nodes' => ['Sample::WidgetsController#index'],
      'observation' => { 'days' => 45 }
    }.to_yaml)
    File.write(config_path, {
      'frameworks' => ['rails'],
      'analyzers' => {
        'static' => %w[name_resolution cha rta],
        'dynamic' => { 'coverage' => { 'source' => coverage_path, 'min_observation_days' => 30 } }
      },
      'entry_points' => { 'extra' => ['Sample::WidgetsController#index'] }
    }.to_yaml)

    report = described_class.analyze(root: fixture_path('sample_project'), config_path: config_path)
    findings = report.findings.to_h { |finding| [finding.node.id, finding] }

    expect(findings.fetch('Sample::Widget#render').classification).to eq(:unused)
  end

  it 'records dynamic method and edge evidence with TracePoint' do
    dir = Dir.mktmpdir
    script = File.join(dir, 'runner.rb')
    output = File.join(dir, 'trace.yml')
    File.write(script, <<~RUBY)
      class RecorderSample
        def a
          b
        end

        def b
          :ok
        end
      end

      RecorderSample.new.a
    RUBY

    Necropsy::Analyzers::Dynamic::TracePointCollector.record(root: dir, output: output) do
      load script
    end
    payload = YAML.load_file(output)

    expect(payload['nodes']).to include('RecorderSample#a', 'RecorderSample#b')
    expect(payload['edges']).to include({ 'caller_id' => 'RecorderSample#a', 'callee_id' => 'RecorderSample#b' })
  end

  it 'records method execution with Coverage' do
    dir = Dir.mktmpdir
    script = File.join(dir, 'runner.rb')
    output = File.join(dir, 'coverage.yml')
    File.write(script, <<~RUBY)
      class CoverageRecorderSample
        def a
          b
        end

        def b
          :ok
        end
      end

      CoverageRecorderSample.new.a
    RUBY

    Necropsy::Analyzers::Dynamic::CoverageCollector.record(root: dir, output: output) do
      load script
    end
    payload = YAML.load_file(output)

    expect(payload['nodes']).to include('CoverageRecorderSample#a', 'CoverageRecorderSample#b')
  end

  it 'records method execution with Coverage from an external command' do
    dir = Dir.mktmpdir
    script = File.join(dir, 'runner.rb')
    output = File.join(dir, 'coverage.yml')
    File.write(script, <<~RUBY)
      class ExternalCoverageRecorderSample
        def a
          :ok
        end
      end

      ExternalCoverageRecorderSample.new.a
    RUBY

    File.write(output, { 'nodes' => ['StaleCoverage#old'], 'observation' => { 'run_id' => 'old' } }.to_yaml)
    status = Necropsy::CLI.run(['coverage', '--root', dir, '--output', output, '--', RbConfig.ruby, script])
    payload = YAML.load_file(output)

    expect(status).to eq(0)
    expect(payload['nodes']).to include('ExternalCoverageRecorderSample#a')
    expect(payload['nodes']).not_to include('StaleCoverage#old')
  end

  it 'merges Coverage output from multiple external Ruby processes' do
    dir = Dir.mktmpdir
    child_a = File.join(dir, 'child_a.rb')
    child_b = File.join(dir, 'child_b.rb')
    runner = File.join(dir, 'runner.rb')
    output = File.join(dir, 'coverage.yml')

    File.write(child_a, <<~RUBY)
      class ExternalCoverageMergeA
        def a
          :ok
        end
      end

      ExternalCoverageMergeA.new.a
    RUBY
    File.write(child_b, <<~RUBY)
      class ExternalCoverageMergeB
        def b
          :ok
        end
      end

      ExternalCoverageMergeB.new.b
    RUBY
    File.write(runner, <<~RUBY)
      require "rbconfig"

      pids = [#{child_a.dump}, #{child_b.dump}].map { |path| Process.spawn(RbConfig.ruby, path) }
      statuses = pids.map { |pid| Process.wait2(pid).last }
      exit(statuses.all?(&:success?) ? 0 : 1)
    RUBY

    status = Necropsy::CLI.run(['coverage', '--root', dir, '--output', output, '--', RbConfig.ruby, runner])
    payload = YAML.load_file(output)

    expect(status).to eq(0)
    expect(payload['nodes']).to include('ExternalCoverageMergeA#a', 'ExternalCoverageMergeB#b')
    expect(payload.fetch('observation').fetch('processes')).to be >= 2
  end

  it 'loads coverband payloads from Redis sources' do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      2.times do
        command = read_redis_command(client)
        case command.first
        when 'SELECT'
          client.write("+OK\r\n")
        when 'GET'
          payload = { 'nodes' => ['Sample::Widget#render'], 'observation' => { 'days' => 30 } }.to_json
          client.write("$#{payload.bytesize}\r\n#{payload}\r\n")
        end
      end
      client.close
    end

    config_path = File.join(Dir.mktmpdir, '.necropsy.yml')
    File.write(config_path, {
      'frameworks' => ['rails'],
      'analyzers' => {
        'static' => %w[name_resolution cha rta],
        'dynamic' => { 'coverband' => { 'source' => "redis://127.0.0.1:#{port}/0?key=coverband" } }
      },
      'entry_points' => { 'extra' => ['Sample::WidgetsController#index'] }
    }.to_yaml)

    report = described_class.analyze(root: fixture_path('sample_project'), config_path: config_path)

    expect(report.graph.dynamic_alive?('Sample::Widget#render')).to eq(true)
  ensure
    thread&.join(1)
    server&.close
  end

  it 'loads coverband Redis hash payloads' do
    model_path = fixture_path('sample_project/app/models/widget.rb')
    render_line = File.readlines(model_path).find_index { |line| line.include?('def render') } + 1
    render_index = render_line - 1
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      3.times do
        command = read_redis_command(client)
        case command.first
        when 'SELECT'
          client.write("+OK\r\n")
        when 'GET'
          client.write("-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
        when 'HGETALL'
          payload = {
            'file' => model_path,
            'file_length' => render_line.to_s,
            render_index.to_s => '2',
            'first_updated_at' => '1',
            'last_updated_at' => '2'
          }
          write_redis_array(client, payload.flat_map { |field, value| [field, value] })
        end
      end
      client.close
    end

    config_path = File.join(Dir.mktmpdir, '.necropsy.yml')
    File.write(config_path, {
      'frameworks' => ['rails'],
      'analyzers' => {
        'static' => %w[name_resolution cha rta],
        'dynamic' => { 'coverband' => { 'source' => "redis://127.0.0.1:#{port}/0?key=coverband:coverage" } }
      }
    }.to_yaml)

    report = described_class.analyze(root: fixture_path('sample_project'), config_path: config_path)

    expect(report.graph.dynamic_alive?('Sample::Widget#render')).to eq(true)
  ensure
    thread&.join(1)
    server&.close
  end

  it 'normalizes coverband line-count payloads' do
    dir = Dir.mktmpdir
    source = File.join(dir, 'coverband.yml')
    config_path = File.join(dir, '.necropsy.yml')
    model_path = fixture_path('sample_project/app/models/widget.rb')
    render_line = File.readlines(model_path).find_index { |line| line.include?('def render') } + 1

    File.write(source, {
      'files' => {
        model_path => { render_line.to_s => 3 }
      },
      'observation' => { 'days' => 30 }
    }.to_yaml)
    File.write(config_path, {
      'frameworks' => ['rails'],
      'analyzers' => {
        'static' => %w[name_resolution cha rta],
        'dynamic' => { 'coverband' => { 'source' => source } }
      }
    }.to_yaml)

    report = described_class.analyze(root: fixture_path('sample_project'), config_path: config_path)

    expect(report.graph.dynamic_alive?('Sample::Widget#render')).to eq(true)
  end

  it 'raises expired quarantined unreachable methods to certain confidence' do
    dir = File.join(Dir.mktmpdir, 'sample_project')
    FileUtils.mkdir_p(dir)
    FileUtils.cp_r(Dir.glob(File.join(fixture_path('sample_project'), '*'), File::FNM_DOTMATCH).reject do |path|
      path.end_with?('/.', '/..')
    end, dir)
    model_path = File.join(dir, 'app/models/widget.rb')
    lines = File.readlines(model_path, chomp: true)
    index = lines.index { |line| line.include?('def dead_model') }
    lines.insert(index, '    # necropsy:quarantine since=2000-01-01')
    File.write(model_path, "#{lines.join("\n")}\n")

    report = described_class.analyze(root: dir)
    finding = report.findings.find { |item| item.node.id == 'Sample::Widget#dead_model' }

    expect(finding.confidence).to eq(:certain)
  end
end

def read_redis_command(io)
  count = io.gets("\r\n").delete_prefix('*').to_i
  Array.new(count) do
    length = io.gets("\r\n").delete_prefix('$').to_i
    value = io.read(length)
    io.read(2)
    value
  end
end

def write_redis_array(io, values)
  io.write("*#{values.length}\r\n")
  values.each do |value|
    string = value.to_s
    io.write("$#{string.bytesize}\r\n#{string}\r\n")
  end
end
