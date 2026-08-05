# frozen_string_literal: true

require 'digest'
require 'json'

module Necropsy
  module CallSiteIdentity
    VERSION = 1
    PREFIX = "call:v#{VERSION}".freeze
    SOURCE_ROLES = %i[
      call initialize symbol_reference symbol_to_proc super alias_target delegate_target delegate_message
    ].freeze
    DERIVATIONS = %i[module_function rta_implicit].freeze

    module_function

    def source_id(caller_definition_id:, relative_path:, role:, message:, structural_digest:, ordinal:)
      role = role.to_sym
      raise ArgumentError, "invalid call site role: #{role.inspect}" unless SOURCE_ROLES.include?(role)

      ordinal = Integer(ordinal)
      raise ArgumentError, 'call site ordinal must be positive' unless ordinal.positive?

      identifier(
        'source', caller_definition_id.to_s, relative_path.to_s, role.to_s, message.to_s,
        structural_digest.to_s, ordinal
      )
    end

    def derived_id(parent_call_site_id:, derivation:, caller_definition_id:, message:)
      derivation = derivation.to_sym
      raise ArgumentError, "invalid call site derivation: #{derivation.inspect}" unless DERIVATIONS.include?(derivation)

      identifier(
        'derived', derivation.to_s, parent_call_site_id.to_s, caller_definition_id.to_s, message.to_s
      )
    end

    def legacy_id(caller_definition_id:, message:, receiver_kind:, receiver_name:, file:, line:, test:, dynamic:,
                  metadata:)
      identifier(
        'legacy', caller_definition_id.to_s, message.to_s, receiver_kind.to_s, receiver_name&.to_s,
        file.to_s, line, test, dynamic, metadata
      )
    end

    def identifier(*payload)
      canonical = canonicalize(payload)
      "#{PREFIX}:#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
    end
    private_class_method :identifier

    def canonicalize(value)
      case value
      when Hash
        pairs = value.map { |key, item| [key.to_s, canonicalize(item)] }.sort_by(&:first)
        ['hash', pairs]
      when Array
        ['array', value.map { |item| canonicalize(item) }]
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
        value.respond_to?(:to_h) ? canonicalize(value.to_h) : [value.class.name, value.to_s]
      end
    end
    private_class_method :canonicalize
  end
end
