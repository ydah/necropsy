# frozen_string_literal: true

require 'digest'
require 'json'
require 'prism'

module Necropsy
  module DefinitionIdentity
    PREFIX = 'def:v1'
    EXCLUDED_KEYS = %i[node_id location flags].freeze

    module_function

    def body_digest(node)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(node)))
    end

    def definition_id(kind:, symbol_id:, relative_path:, body_digest:, ordinal:)
      ordinal = Integer(ordinal)
      raise ArgumentError, 'definition ordinal must be positive' unless ordinal.positive?

      payload = [kind.to_s, symbol_id.to_s, relative_path.to_s, body_digest.to_s, ordinal]
      "#{PREFIX}:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def canonicalize(value)
      case value
      when Prism::Node
        canonical_node(value)
      when Prism::Location
        nil
      when Array
        ['array', value.map { |item| canonicalize(item) }]
      when Hash
        canonical_hash(value)
      when Symbol
        ['symbol', value.to_s]
      when String
        ['string', value]
      when Integer
        ['integer', value.to_s]
      when Float
        ['float', value.to_s]
      when true, false
        ['boolean', value]
      when nil
        ['nil']
      else
        [value.class.name, value.to_s]
      end
    end
    private_class_method :canonicalize

    def canonical_node(node)
      fields = node.deconstruct_keys(nil).filter_map do |key, value|
        next if excluded_key?(key)

        [key.to_s, canonicalize(value)]
      end
      semantic_flags = node.send(:flags) & ~Prism::NodeFlags::NEWLINE
      ['node', node.type.to_s, semantic_flags, fields.sort_by(&:first)]
    end
    private_class_method :canonical_node

    def canonical_hash(value)
      pairs = value.sort_by { |key, _item| [key.class.name, key.to_s] }.map do |key, item|
        [canonicalize(key), canonicalize(item)]
      end
      ['hash', pairs]
    end
    private_class_method :canonical_hash

    def excluded_key?(key)
      name = key.to_s
      EXCLUDED_KEYS.include?(key.to_sym) || name.end_with?('_loc', 'comment', 'comments')
    end
    private_class_method :excluded_key?
  end
end
