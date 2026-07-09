# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'yaml'

module Necropsy
  module Analyzers
    module Dynamic
      class TracePointCollector
        def self.record(root:, output:, sample_rate: 1.0, &)
          new(root: root, output: output, sample_rate: sample_rate).record(&)
        end

        def initialize(root:, output:, sample_rate: 1.0)
          @root = File.expand_path(root)
          @output = output
          @sample_rate = sample_rate.to_f
          @nodes = {}
          @edges = {}
          @stack = []
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

        private

        attr_reader :root, :output, :sample_rate, :nodes, :edges, :stack

        def capture(event)
          return unless project_path?(event.path)
          return if sample_rate < 1.0 && SecureRandom.random_number > sample_rate

          node_id = node_id_for(event)
          return unless node_id

          if event.event == :return
            stack.pop if stack.last == node_id
            return
          end

          caller_id = stack.last
          nodes[node_id] = true
          edges[[caller_id, node_id]] = true if caller_id

          stack << node_id
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
          File.write(output, payload.to_yaml)
        end
      end
    end
  end
end
