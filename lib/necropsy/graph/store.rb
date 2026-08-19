# frozen_string_literal: true

module Necropsy
  class GraphStore
    attr_reader :nodes, :physical_edges, :incoming_edges, :entry_points, :profiles, :dynamic_alive, :uncertainties

    def initialize(uncertainties: {})
      @nodes = DefinitionIndex.new
      @physical_edges = {}
      @incoming_edges = {}
      @entry_points = []
      @profiles = []
      @dynamic_alive = {}
      @uncertainties = uncertainties.to_h do |node_id, messages|
        [node_id, Array(messages).dup]
      end
    end

    def duplicate_with(memo)
      return memo.fetch(self) if memo.key?(self)

      copy = dup
      memo[self] = copy
      instance_variables.each do |name|
        value = instance_variable_get(name)
        copy.instance_variable_set(name, yield(value, memo))
      end
      copy
    end
  end
end
