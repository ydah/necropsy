# frozen_string_literal: true

require 'digest'
require_relative 'bounded_canonicalizer'

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

    def derived_id(parent_call_site_id:, derivation:, caller_definition_id:, message:, discriminator: nil)
      derivation = derivation.to_sym
      raise ArgumentError, "invalid call site derivation: #{derivation.inspect}" unless DERIVATIONS.include?(derivation)

      payload = [
        'derived', derivation.to_s, parent_call_site_id.to_s, caller_definition_id.to_s, message.to_s
      ]
      payload << discriminator.to_s unless discriminator.nil?
      identifier(*payload)
    end

    def legacy_id(caller_definition_id:, message:, receiver_kind:, receiver_name:, file:, line:, test:, dynamic:,
                  metadata:)
      identifier(
        'legacy', caller_definition_id.to_s, message.to_s, receiver_kind.to_s, receiver_name&.to_s,
        file.to_s, line, test, dynamic, metadata
      )
    end

    def identifier(*payload)
      "#{PREFIX}:#{Digest::SHA256.hexdigest(BoundedCanonicalizer.dump(payload))}"
    end
    private_class_method :identifier
  end
end
