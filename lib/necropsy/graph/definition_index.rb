# frozen_string_literal: true

module Necropsy
  class DefinitionIndex
    include Enumerable

    Lookup = Data.define(:identifier, :status, :definitions) do
      def exact?
        status == :exact
      end

      def unique?
        status == :unique
      end

      def ambiguous?
        status == :ambiguous
      end

      def missing?
        status == :missing
      end

      def node
        definitions.first if exact? || unique?
      end
    end

    class AmbiguousDefinitionError < KeyError
      attr_reader :lookup

      def initialize(lookup)
        @lookup = lookup
        super("#{lookup.identifier.inspect} matches #{lookup.definitions.length} physical definitions")
      end
    end

    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    def initialize(definitions = [])
      @by_definition_id = {}
      @by_symbol_id = Hash.new { |hash, key| hash[key] = [] }
      definitions.each { |definition| add(definition) }
    end

    def add(definition)
      existing = @by_definition_id[definition.graph_id]
      return existing if existing == definition
      raise ArgumentError, "duplicate physical definition ID: #{definition.graph_id}" if existing

      @by_definition_id[definition.graph_id] = definition
      @by_symbol_id[definition.symbol_id] << definition
      definition
    end

    def exact(definition_id)
      @by_definition_id[definition_id]
    end

    def definitions_for(symbol_id)
      sorted(@by_symbol_id.fetch(symbol_id, [])).freeze
    end

    def lookup(identifier)
      exact_match = exact(identifier)
      return Lookup.new(identifier: identifier, status: :exact, definitions: [exact_match].freeze) if exact_match

      definitions = definitions_for(identifier)
      status = if definitions.empty?
                 :missing
               elsif definitions.one?
                 :unique
               else
                 :ambiguous
               end
      Lookup.new(identifier: identifier, status: status, definitions: definitions)
    end

    def [](identifier)
      result = lookup(identifier)
      raise AmbiguousDefinitionError, result if result.ambiguous?

      result.node
    end

    def fetch(identifier, default = UNDEFINED)
      result = lookup(identifier)
      raise AmbiguousDefinitionError, result if result.ambiguous?
      return result.node unless result.missing?
      return yield(identifier) if block_given?
      return default unless default.equal?(UNDEFINED)

      raise KeyError, "key not found: #{identifier.inspect}"
    end

    def key?(identifier)
      !lookup(identifier).missing?
    end

    def each
      return enum_for(:each) unless block_given?

      values.each { |definition| yield(definition.graph_id, definition) }
      self
    end

    def each_key
      return enum_for(:each_key) unless block_given?

      values.each { |definition| yield definition.graph_id }
      self
    end

    def each_value(&block)
      return enum_for(:each_value) unless block

      values.each(&block)
      self
    end

    def keys
      values.map(&:graph_id)
    end

    def values
      sorted(@by_definition_id.values)
    end

    def length
      @by_definition_id.length
    end
    alias size length

    def empty?
      @by_definition_id.empty?
    end

    private

    def sorted(definitions)
      definitions.sort_by do |definition|
        [definition.symbol_id.to_s, definition.file.to_s, definition.line.to_i, definition.graph_id.to_s]
      end
    end
  end
end
