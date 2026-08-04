# frozen_string_literal: true

require 'json'
require 'optparse'
require 'yaml'
require_relative '../lib/necropsy'
require_relative '../lib/necropsy/bench/seed_runner'
require_relative '../lib/necropsy/bench/release_audit'
require_relative '../lib/necropsy/bench/release_audit/adversarial_runner'
require_relative '../lib/necropsy/bench/release_audit/artifact_writer'
require_relative '../lib/necropsy/bench/release_audit/config_validator'
require_relative '../lib/necropsy/bench/release_audit/git_snapshot'
require_relative '../lib/necropsy/bench/release_audit/run_provenance'

root = File.expand_path('..', __dir__)
options = {
  config: File.join(__dir__, 'audits/0.2.1/config.yml'),
  benchmark_output: File.join(root, 'tmp/necropsy-benchmark/v1'),
  audit_output: File.join(__dir__, 'audits/0.2.1'),
  run_benchmark: true,
  run_adversarial: true
}

OptionParser.new do |parser|
  parser.banner = 'Usage: bundle exec ruby bench/audit.rb [options]'
  parser.on('--config PATH', 'Audit configuration') { |path| options[:config] = path }
  parser.on('--benchmark-output DIR', 'Current benchmark output') { |path| options[:benchmark_output] = path }
  parser.on('--output DIR', 'Audit artifact output') { |path| options[:audit_output] = path }
  parser.on('--skip-benchmark', 'Use an existing current benchmark run') { options[:run_benchmark] = false }
  parser.on('--skip-adversarial', 'Do not execute adversarial suites') { options[:run_adversarial] = false }
end.parse!

config_path = File.expand_path(options.fetch(:config), root)
config = YAML.safe_load_file(config_path, aliases: false)
Necropsy::Bench::ReleaseAudit::ConfigValidator.new(config).validate!

manifest_path = File.join(root, 'bench/corpora/v1/manifest.yml')
benchmark_output = File.expand_path(options.fetch(:benchmark_output), root)
provenance_path = File.join(benchmark_output, 'run_metadata.json')
rubocop_corpus = ENV.fetch('NECROPSY_RUBOCOP_CORPUS', '<unset>')
measurement_command = "NECROPSY_RUBOCOP_CORPUS=#{rubocop_corpus} bundle exec ruby bench/run.rb"
provenance = Necropsy::Bench::ReleaseAudit::RunProvenance.new(
  root: root,
  manifest_path: manifest_path,
  config_path: config_path,
  output_dir: benchmark_output,
  command: measurement_command
)

current_provenance = if options[:run_benchmark]
                       source = provenance.capture_source!
                       summary = Necropsy::Bench::SeedRunner.new(
                         manifest_path: manifest_path,
                         output_dir: benchmark_output
                       ).call
                       provenance.complete(source, summary).tap do |payload|
                         provenance.write(provenance_path, payload)
                       end
                     else
                       provenance.load_and_validate!(provenance_path)
                     end

corpora = config.fetch('corpora')
current_reports = corpora.to_h do |corpus|
  path = File.join(benchmark_output, 'reports', "#{corpus}.json")
  [corpus, JSON.parse(File.read(path))]
end
current_summary = JSON.parse(File.read(File.join(benchmark_output, 'summary.json')))
baseline = config.fetch('baseline')
baseline_reports = Necropsy::Bench::ReleaseAudit::GitSnapshot.new(
  root: root,
  git_ref: baseline.fetch('git_ref'),
  reports_path: baseline.fetch('reports_path')
).reports(corpora)

load_yaml = lambda do |relative|
  YAML.safe_load_file(File.expand_path(relative, root), aliases: false) || {}
end
label_entries = Array(load_yaml.call(config.fetch('labels_path'))['labels'])
labels = label_entries.to_h { |entry| [[entry.fetch('corpus'), entry.fetch('id')], entry] }
reviews = Array(load_yaml.call(config.dig('review', 'path'))['reviews'])
baseline_performance = load_yaml.call(config.dig('performance', 'baseline_path'))
adversarial_results = if options[:run_adversarial]
                        Necropsy::Bench::ReleaseAudit::AdversarialRunner.new(
                          root: root,
                          suites: config.fetch('adversarial_suites')
                        ).call
                      else
                        config.fetch('adversarial_suites').sort.map do |name, definition|
                          { 'name' => name, 'command' => definition.fetch('command'), 'passed' => false,
                            'exit_status' => nil, 'duration_seconds' => 0.0, 'summary' => 'not run' }
                        end
                      end

audit = Necropsy::Bench::ReleaseAudit.new(
  config: config,
  baseline_reports: baseline_reports,
  current_reports: current_reports,
  current_summary: current_summary,
  labels: labels,
  reviews: reviews,
  baseline_performance: baseline_performance,
  adversarial_results: adversarial_results,
  current_provenance: current_provenance
).call
paths = Necropsy::Bench::ReleaseAudit::ArtifactWriter.new(
  audit: audit,
  output_dir: File.expand_path(options.fetch(:audit_output), root)
).call
puts "release audit: #{audit.fetch('status')}"
puts "machine artifact: #{paths.fetch(:json)}"
puts "human artifact: #{paths.fetch(:markdown)}"
exit(audit.fetch('status') == 'pass' ? 0 : 1)
