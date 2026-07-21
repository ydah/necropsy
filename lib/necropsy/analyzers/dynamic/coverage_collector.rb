# frozen_string_literal: true

require 'coverage'
require 'fileutils'
require 'time'
require 'yaml'

module Necropsy
  module Analyzers
    module Dynamic
      class CoverageCollector
        def self.record(root:, output:, &)
          new(root: root, output: output).record(&)
        end

        def self.install_at_exit(root:, output:, merge: false, run_id: nil)
          new(root: root, output: output, merge: merge, run_id: run_id).install_at_exit
        end

        def initialize(root:, output:, merge: false, run_id: nil)
          @root = File.expand_path(root)
          @output = output
          @merge = merge
          @run_id = run_id
        end

        def record
          started_at = Time.now.utc
          Coverage.start(methods: true)
          yield
          write_payload(result: Coverage.result, started_at: started_at, finished_at: Time.now.utc)
        ensure
          Coverage.result(stop: true, clear: true) if Coverage.running?
        end

        def install_at_exit
          started_at = Time.now.utc
          started = start_coverage

          at_exit do
            finished_at = Time.now.utc
            result = coverage_result(started: started)
            write_payload(result: result, started_at: started_at, finished_at: finished_at)
          rescue StandardError => e
            warn "Necropsy coverage collector failed: #{e.message}"
          end
        end

        private

        attr_reader :root, :output, :run_id

        def merge?
          @merge
        end

        def start_coverage
          return false if Coverage.running?

          Coverage.start(methods: true)
          true
        end

        def coverage_result(started:)
          return Coverage.result(stop: true, clear: true) if started && Coverage.running?
          if Coverage.respond_to?(:peek_result) && Coverage.running?
            result = Coverage.peek_result
            return result if method_coverage?(result)

            warn 'Necropsy coverage collector found Coverage already running without methods: true; no methods were recorded.'
          end

          {}
        end

        def method_coverage?(result)
          result.values.any? { |coverage| coverage.is_a?(Hash) && coverage.key?(:methods) }
        end

        def write_payload(result:, started_at:, finished_at:)
          payload = {
            'nodes' => executed_nodes(result).sort,
            'observation' => {
              'started_at' => started_at.iso8601,
              'finished_at' => finished_at.iso8601,
              'days' => [((finished_at - started_at) / 86_400.0).ceil, 1].max,
              'collector' => 'coverage'
            }.tap { |observation| observation['run_id'] = run_id if run_id }
          }
          FileUtils.mkdir_p(File.dirname(output))
          merge? ? write_merged_payload(payload) : File.write(output, payload.to_yaml)
        end

        def write_merged_payload(payload)
          File.open(output, File::RDWR | File::CREAT, 0o644) do |file|
            file.flock(File::LOCK_EX)
            existing = payload_for_current_run(read_payload(file), payload)
            merged = merge_payload(existing, payload)
            file.rewind
            file.truncate(0)
            file.write(merged.to_yaml)
            file.flush
          end
        end

        def read_payload(file)
          file.rewind
          content = file.read
          return {} if content.empty?

          YAML.load(content) || {}
        rescue Psych::Exception
          {}
        end

        def payload_for_current_run(existing, payload)
          current_run = payload.dig('observation', 'run_id')
          return existing unless current_run
          return existing if empty_payload?(existing)
          return existing if existing.dig('observation', 'run_id') == current_run

          {}
        end

        def empty_payload?(payload)
          Array(payload['nodes']).empty? && payload.fetch('observation', {}).empty?
        end

        def merge_payload(left, right)
          observation = merge_observation(left.fetch('observation', {}), right.fetch('observation', {}))
          {
            'nodes' => (Array(left['nodes']) + Array(right['nodes'])).uniq.sort,
            'observation' => observation
          }
        end

        def merge_observation(left, right)
          started_at = [left['started_at'], right['started_at']].compact.min
          finished_at = [left['finished_at'], right['finished_at']].compact.max
          observation = left.merge(right)
          observation['started_at'] = started_at if started_at
          observation['finished_at'] = finished_at if finished_at
          observation['days'] = merged_days(left, right, started_at, finished_at)
          observation['collector'] = 'coverage'
          observation['processes'] = process_count(left) + process_count(right)
          observation
        end

        def merged_days(left, right, started_at, finished_at)
          observed_days = [left['days'].to_i, right['days'].to_i, days_between(started_at, finished_at)].max
          [observed_days, 1].max
        end

        def days_between(started_at, finished_at)
          return 0 unless started_at && finished_at

          [((Time.parse(finished_at) - Time.parse(started_at)) / 86_400.0).ceil, 1].max
        rescue ArgumentError
          0
        end

        def process_count(observation)
          return observation['processes'].to_i if observation['processes']
          return 0 if observation.empty?

          1
        end

        def executed_nodes(result)
          result.flat_map do |path, coverage|
            next [] unless project_path?(path)

            coverage.fetch(:methods, {}).filter_map do |method_key, count|
              next unless count.to_i.positive?

              node_id_for(method_key)
            end
          end
        end

        def project_path?(path)
          File.expand_path(path).start_with?("#{root}/")
        end

        def node_id_for(method_key)
          owner = method_key[0]
          method_name = method_key[1]
          owner_name, separator = owner_and_separator(owner)
          return nil unless owner_name

          "#{owner_name}#{separator}#{method_name}"
        end

        def owner_and_separator(owner)
          return [owner.name, '#'] if owner.respond_to?(:name) && owner.name

          singleton_owner = owner.inspect[/\A#<Class:(.+)>\z/, 1]
          return [singleton_owner, '.'] if singleton_owner

          nil
        end
      end
    end
  end
end
