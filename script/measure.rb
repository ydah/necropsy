# frozen_string_literal: true

require_relative '../lib/necropsy'

root = File.expand_path(ARGV[0] || '.', Dir.pwd)
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
report = Necropsy.analyze(root: root)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
node_count = report.graph.nodes.size

puts({
  root: root,
  nodes: node_count,
  edges: report.graph.edges.size,
  findings: report.findings.size,
  ratio: node_count.zero? ? 0.0 : (100.0 * report.findings.size / node_count).round(1),
  by_confidence: report.findings.group_by(&:confidence).transform_values(&:size),
  seconds: elapsed.round(2)
}.inspect)
