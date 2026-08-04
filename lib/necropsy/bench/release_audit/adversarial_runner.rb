# frozen_string_literal: true

require 'open3'

module Necropsy
  module Bench
    class ReleaseAudit
      class AdversarialRunner
        def initialize(root:, suites:, clock: Process.method(:clock_gettime))
          @root = root
          @suites = suites
          @clock = clock
        end

        def call
          suites.sort.map do |name, definition|
            command = definition.fetch('command').map(&:to_s)
            started_at = monotonic_time
            stdout, stderr, status = Open3.capture3(*command, chdir: root)
            {
              'name' => name,
              'command' => command,
              'passed' => status.success?,
              'exit_status' => status.exitstatus,
              'duration_seconds' => (monotonic_time - started_at).round(6),
              'summary' => result_summary(stdout, stderr)
            }
          rescue SystemCallError => e
            {
              'name' => name,
              'command' => command,
              'passed' => false,
              'exit_status' => nil,
              'duration_seconds' => (monotonic_time - started_at).round(6),
              'summary' => "#{e.class}: #{e.message}"
            }
          end
        end

        private

        attr_reader :root, :suites, :clock

        def monotonic_time
          clock.call(Process::CLOCK_MONOTONIC)
        end

        def result_summary(stdout, stderr)
          combined = [stdout, stderr].join("\n")
          combined.lines.map(&:strip).reverse.find { |line| line.match?(/\d+ examples?, \d+ failures?/) } ||
            combined.lines.map(&:strip).reject(&:empty?).last.to_s
        end
      end
    end
  end
end
