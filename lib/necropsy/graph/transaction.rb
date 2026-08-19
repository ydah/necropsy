# frozen_string_literal: true

module Necropsy
  module Graph
    class Transaction
      def self.apply(graph, result, refresh: true)
        new(graph).apply(result, refresh: refresh)
      end

      def initialize(graph)
        @graph = graph
      end

      def apply(result, refresh: true)
        staged = duplicate_graph
        staged.send(:apply_result!, result, refresh: refresh)
        staged.instance_variables.each do |name|
          @graph.instance_variable_set(name, staged.instance_variable_get(name))
        end
        @graph.instance_variable_get(:@evidence_ledger)&.bind(@graph)
        nil
      end

      private

      def duplicate_graph
        copy = @graph.dup
        memo = {}.compare_by_identity
        @graph.instance_variables.each do |name|
          value = @graph.instance_variable_get(name)
          copy.instance_variable_set(name, duplicate_value(value, memo))
        end
        copy.instance_variable_get(:@evidence_ledger)&.bind(copy)
        copy
      end

      def duplicate_value(value, memo)
        return memo.fetch(value) if memo.key?(value)

        case value
        when Graph::Store, Graph::EvidenceLedger
          value.duplicate_with(memo) { |item, state| duplicate_value(item, state) }
        when Hash
          duplicate_hash(value, memo)
        when Array
          duplicate_array(value, memo)
        when Set
          duplicate_set(value, memo)
        else
          value
        end
      end

      def duplicate_hash(value, memo)
        copy = {}
        copy.compare_by_identity if value.compare_by_identity?
        copy.default_proc = value.default_proc if value.default_proc
        copy.default = value.default unless value.default_proc
        memo[value] = copy
        value.each { |key, item| copy[key] = duplicate_value(item, memo) }
        copy
      end

      def duplicate_array(value, memo)
        copy = []
        memo[value] = copy
        value.each { |item| copy << duplicate_value(item, memo) }
        copy
      end

      def duplicate_set(value, memo)
        copy = Set.new
        memo[value] = copy
        value.each { |item| copy.add(duplicate_value(item, memo)) }
        copy
      end
    end
  end
end
