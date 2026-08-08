# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'optparse'
require 'yaml'
require_relative '../lib/necropsy'

root = File.expand_path('..', __dir__)
options = {
  input: File.join(root, 'bench/golden/v1/reports'),
  output: File.join(root, 'bench/audits/0.2.1/review_queue.yml'),
  target: 300
}

OptionParser.new do |parser|
  parser.banner = 'Usage: bundle exec ruby bench/review_queue.rb [options]'
  parser.on('--input DIR', 'Directory containing normalized report JSON files') { |path| options[:input] = path }
  parser.on('--output PATH', 'Review queue YAML output path') { |path| options[:output] = path }
  parser.on('--target COUNT', Integer, 'Required reviewed high-candidate target') { |count| options[:target] = count }
end.parse!

reports = Dir.glob(File.join(File.expand_path(options.fetch(:input), root), '*.json')).to_h do |path|
  [File.basename(path, '.json'), JSON.parse(File.read(path))]
end
raise Necropsy::Error, 'No normalized reports were found for review queue generation' if reports.empty?

queue = Necropsy::Bench::ReviewQueue.new(
  reports: reports,
  target_reviewed_high: options.fetch(:target)
).call
output = File.expand_path(options.fetch(:output), root)
FileUtils.mkdir_p(File.dirname(output))
File.write(output, YAML.dump(queue))
puts "review queue: #{output} (#{queue.fetch('queued_candidates')} pending entries)"
