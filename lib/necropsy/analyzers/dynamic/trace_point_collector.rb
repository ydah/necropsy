# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'time'
require 'yaml'

module Necropsy
  module Analyzers
    module Dynamic
      class TracePointCollector
        def self.record(root:, output:, sample_rate: 1.0, &)
          new(root: root, output: output, sample_rate: sample_rate).record(&)
        end

        def self.install_at_exit(root:, output:, sample_rate: 1.0, merge: false, run_id: nil)
          new(root: root, output: output, sample_rate: sample_rate, merge: merge, run_id: run_id).install_at_exit
        end

        def initialize(root:, output:, sample_rate: 1.0, merge: false, run_id: nil)
          @root = File.expand_path(root)
          @output = output
          @sample_rate = sample_rate.to_f
          raise Error, 'sample_rate must be between 0.0 and 1.0' unless @sample_rate.between?(0.0, 1.0)

          @nodes = {}
          @edges = {}
          @stacks = {}
          @lock = Mutex.new
          @merge = merge
          @run_id = run_id
        end

        def record
          started_at = Time.now.utc
          tracer = TracePoint.new(:call, :return) { |event| capture(event) }
          tracer.enable
          yield
        ensure
          tracer&.disable
          write_payload(started_at: started_at, finished_at: Time.now.utc)
        end

        def install_at_exit
          started_at = Time.now.utc
          tracer = TracePoint.new(:call, :return) { |event| capture(event) }
          tracer.enable
          at_exit do
            tracer.disable
            write_payload(started_at: started_at, finished_at: Time.now.utc)
          rescue StandardError => e
            warn "Necropsy TracePoint collector failed: #{e.message}"
          end
        end

        private

        attr_reader :root, :output, :sample_rate, :nodes, :edges, :stacks, :lock, :run_id

        def merge?
          @merge
        end

        def capture(event)
          return unless project_path?(event.path)

          node_id = node_id_for(event)
          return unless node_id

          lock.synchronize do
            stack = stacks[Thread.current.object_id] ||= []
            if event.event == :return
              unwind_stack(stack, node_id)
              stacks.delete(Thread.current.object_id) if stack.empty?
              return
            end

            sampled = sample_rate >= 1.0 || (sample_rate.positive? && SecureRandom.random_number < sample_rate)
            caller_id = stack.last&.first if stack.last&.last
            if sampled
              nodes[node_id] = true
              edges[[caller_id, node_id]] = true if caller_id
            end
            stack << [node_id, sampled]
          end
        end

        def unwind_stack(stack, node_id)
          index = stack.rindex { |frame| frame.first == node_id }
          return unless index

          stack.slice!(index..)
        end

        def project_path?(path)
          return false unless path

          File.expand_path(path).start_with?("#{root}/")
        end

        def node_id_for(event)
          owner, separator = owner_and_separator(event.defined_class)
          return nil unless owner

          "#{owner}#{separator}#{event.method_id}"
        end

        def owner_and_separator(defined_class)
          name = defined_class.name
          return [name, '#'] if name

          singleton_owner = defined_class.inspect[/\A#<Class:(.+)>\z/, 1]
          return [singleton_owner, '.'] if singleton_owner

          nil
        end

        def write_payload(started_at:, finished_at:)
          payload = {
            'nodes' => nodes.keys.sort,
            'edges' => edges.keys.map { |caller_id, callee_id| { 'caller_id' => caller_id, 'callee_id' => callee_id } },
            'observation' => {
              'started_at' => started_at.iso8601,
              'finished_at' => finished_at.iso8601,
              'days' => [((finished_at - started_at) / 86_400.0).ceil, 1].max,
              'sample_rate' => sample_rate
            }
          }
          payload['observation']['run_id'] = run_id if run_id
          FileUtils.mkdir_p(File.dirname(output))
          merge? ? write_merged_payload(payload) : File.write(output, payload.to_yaml)
        end

        def write_merged_payload(payload)
          File.open(output, File::RDWR | File::CREAT, 0o644) do |file|
            file.flock(File::LOCK_EX)
            existing = trace_payload_for_current_run(read_payload(file), payload)
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

        def trace_payload_for_current_run(existing, payload)
          current_run = payload.dig('observation', 'run_id')
          return existing unless current_run
          return existing if existing.empty? || existing.dig('observation', 'run_id') == current_run

          {}
        end

        def merge_payload(left, right)
          edges = (Array(left['edges']) + Array(right['edges'])).uniq do |edge|
            [edge['caller_id'], edge['callee_id']]
          end
          left_observation = left.fetch('observation', {})
          right_observation = right.fetch('observation', {})
          observation = left_observation.merge(right_observation)
          observation['started_at'] = [left_observation['started_at'], right_observation['started_at']].compact.min
          observation['finished_at'] = [left_observation['finished_at'], right_observation['finished_at']].compact.max
          observation['days'] = [left_observation['days'].to_i, right_observation['days'].to_i, 1].max
          observation['processes'] = process_count(left_observation) + process_count(right_observation)
          {
            'nodes' => (Array(left['nodes']) + Array(right['nodes'])).uniq.sort,
            'edges' => edges,
            'observation' => observation
          }
        end

        def process_count(observation)
          return observation['processes'].to_i if observation['processes']
          return 0 if observation.empty?

          1
        end
      end
    end
  end
end
