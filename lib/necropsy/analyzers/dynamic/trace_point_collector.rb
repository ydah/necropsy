# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'time'
require 'yaml'
require_relative 'runtime_reference'

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
          @node_references = {}
          @edges = {}
          @edge_references = {}
          @stacks = {}.compare_by_identity
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

        attr_reader :root, :output, :sample_rate, :nodes, :node_references, :edges, :edge_references, :stacks, :lock,
                    :run_id

        def merge?
          @merge
        end

        def capture(event)
          return unless project_path?(event.path)

          reference = node_reference_for(event)
          return unless reference

          lock.synchronize do
            stack = stacks[Thread.current] ||= []
            if event.event == :return
              unwind_stack(stack, reference)
              stacks.delete(Thread.current) if stack.empty?
              return
            end

            sampled = sample_rate >= 1.0 || (sample_rate.positive? && SecureRandom.random_number < sample_rate)
            caller_reference = stack.last&.first if stack.last&.last
            if sampled
              record_node(reference)
              record_edge(caller_reference, reference) if caller_reference
            end
            stack << [reference, sampled]
          end
        end

        def unwind_stack(stack, reference)
          reference_key = frame_key(reference)
          index = stack.rindex { |frame| frame_key(frame.first) == reference_key }
          return unless index

          stack.slice!(index..)
        end

        def frame_key(reference)
          RuntimeReference.key(reference)
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

        def node_reference_for(event)
          symbol_id = node_id_for(event)
          return unless symbol_id

          RuntimeReference.build(
            symbol_id: symbol_id,
            file: RuntimeReference.relative_file(root, event.path),
            line: event.respond_to?(:lineno) ? event.lineno : nil
          )
        end

        def record_node(reference)
          nodes[reference.fetch('symbol_id')] = true
          node_references[RuntimeReference.key(reference)] = reference
        end

        def record_edge(caller, callee)
          edges[[caller.fetch('symbol_id'), callee.fetch('symbol_id')]] = true
          key = [RuntimeReference.key(caller), RuntimeReference.key(callee)]
          edge_references[key] = { 'caller_id' => caller.dup, 'callee_id' => callee.dup }
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
            'node_references' => node_references.values.sort_by { |reference| RuntimeReference.sort_key(reference) },
            'edges' => legacy_edges,
            'edge_references' => structured_edges,
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
            'node_references' => merge_node_references(left['node_references'], right['node_references']),
            'edges' => edges,
            'edge_references' => merge_edge_references(left['edge_references'], right['edge_references']),
            'observation' => observation
          }
        end

        def legacy_edges
          edges.keys.sort.map { |caller_id, callee_id| { 'caller_id' => caller_id, 'callee_id' => callee_id } }
        end

        def structured_edges
          edge_references.values.sort_by do |edge|
            [RuntimeReference.sort_key(edge.fetch('caller_id')), RuntimeReference.sort_key(edge.fetch('callee_id'))]
          end
        end

        def merge_node_references(left, right)
          (Array(left) + Array(right))
            .filter_map { |reference| RuntimeReference.normalize(reference) }
            .uniq { |reference| RuntimeReference.key(reference) }
            .sort_by { |reference| RuntimeReference.sort_key(reference) }
        end

        def merge_edge_references(left, right)
          (Array(left) + Array(right)).filter_map do |edge|
            next unless edge.is_a?(Hash)

            caller = RuntimeReference.normalize(edge['caller_id'] || edge[:caller_id])
            callee = RuntimeReference.normalize(edge['callee_id'] || edge[:callee_id])
            { 'caller_id' => caller, 'callee_id' => callee } if caller && callee
          end.uniq do |edge|
            [RuntimeReference.key(edge.fetch('caller_id')), RuntimeReference.key(edge.fetch('callee_id'))]
          end.sort_by do |edge|
            [RuntimeReference.sort_key(edge.fetch('caller_id')), RuntimeReference.sort_key(edge.fetch('callee_id'))]
          end
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
