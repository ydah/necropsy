# frozen_string_literal: true

require 'coverage'
require 'fileutils'
require 'time'
require 'yaml'
require_relative 'runtime_reference'

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
          references = executed_references(result)
          payload = {
            'schema_version' => 2,
            'collector' => { 'name' => 'necropsy-coverage', 'version' => Necropsy::VERSION },
            'scope' => { 'sample_unit' => 'process', 'sample_rate' => 1.0 },
            'quality' => { 'dropped_events' => 0, 'overflowed' => false },
            'nodes' => references.map { |reference| reference.fetch('symbol_id') }.uniq.sort,
            'node_references' => references,
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

          YAML.safe_load(content, aliases: false) || {}
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
          Array(payload['nodes']).empty? && Array(payload['node_references']).empty? &&
            payload.fetch('observation', {}).empty?
        end

        def merge_payload(left, right)
          observation = merge_observation(left.fetch('observation', {}), right.fetch('observation', {}))
          {
            'schema_version' => [left['schema_version'], right['schema_version'], 2].compact.max,
            'collector' => right['collector'] || left['collector'],
            'scope' => right['scope'] || left['scope'],
            'quality' => right['quality'] || left['quality'],
            'nodes' => (Array(left['nodes']) + Array(right['nodes'])).uniq.sort,
            'node_references' => merge_references(left['node_references'], right['node_references']),
            'observation' => observation
          }
        end

        def merge_observation(left, right)
          started_at = [left['started_at'], right['started_at']].compact.min
          finished_at = [left['finished_at'], right['finished_at']].compact.max
          observation = ObservationPolicy.compatible_merge(left, right)
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

        def executed_references(result)
          result.flat_map do |path, coverage|
            next [] unless project_path?(path)

            coverage.fetch(:methods, {}).filter_map do |method_key, count|
              next unless count.to_i.positive?

              node_reference_for(path, method_key)
            end
          end.uniq { |reference| RuntimeReference.key(reference) }.sort_by { |reference| RuntimeReference.sort_key(reference) }
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

        def node_reference_for(path, method_key)
          symbol_id = node_id_for(method_key)
          return unless symbol_id

          RuntimeReference.build(
            symbol_id: symbol_id,
            file: RuntimeReference.relative_file(root, path),
            line: method_key[2]
          )
        end

        def merge_references(left, right)
          (Array(left) + Array(right))
            .filter_map { |reference| RuntimeReference.normalize(reference) }
            .uniq { |reference| RuntimeReference.key(reference) }
            .sort_by { |reference| RuntimeReference.sort_key(reference) }
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
