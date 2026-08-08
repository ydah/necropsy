# frozen_string_literal: true

require 'optparse'
require_relative '../lib/necropsy'
require_relative '../lib/necropsy/bench/seed_runner'

root = File.expand_path('..', __dir__)
options = {
  manifest: File.join(__dir__, 'corpora/v1/manifest.yml'),
  output: File.join(root, 'tmp/necropsy-benchmark/v1')
}

OptionParser.new do |parser|
  parser.banner = 'Usage: bundle exec ruby bench/run.rb [options]'
  parser.on('--manifest PATH', 'Corpus manifest path') { |path| options[:manifest] = path }
  parser.on('--output DIR', 'Generated result directory') { |path| options[:output] = path }
  parser.on('--update-golden REASON', 'Replace deterministic golden files with an audit reason') do |reason|
    options[:update_golden_reason] = reason
  end
end.parse!

runner = Necropsy::Bench::SeedRunner.new(
  manifest_path: options.fetch(:manifest),
  output_dir: options.fetch(:output)
)
summary = runner.call(update_golden_reason: options[:update_golden_reason])
puts "summary: #{File.join(File.expand_path(options.fetch(:output)), 'summary.json')}"
failed_corpus = summary.fetch('corpora').any? { |corpus| corpus['status'] == 'failed' }
golden_mismatch = summary.dig('golden', 'status') != 'match'
precision_failure = summary.dig('precision_gate', 'passed') == false
exit(failed_corpus || golden_mismatch || precision_failure ? 1 : 0)
