# frozen_string_literal: true

require 'prism'
require_relative 'definition_identity/canonical_digest'

module Necropsy
  module DefinitionIdentity
    VERSION = 1
    PREFIX = "def:v#{VERSION}".freeze
    EXCLUDED_KEYS = %i[node_id location flags].freeze

    module_function

    def body_digest(node, **limits)
      CanonicalDigest.new(**limits).hexdigest(node)
    end

    def definition_id(kind:, symbol_id:, relative_path:, body_digest:, ordinal:)
      ordinal = Integer(ordinal)
      raise ArgumentError, 'definition ordinal must be positive' unless ordinal.positive?

      payload = [kind.to_s, symbol_id.to_s, relative_path.to_s, body_digest.to_s, ordinal]
      "#{PREFIX}:#{CanonicalDigest.new.hexdigest_payload(payload)}"
    end

    def file_root_id(relative_path:)
      payload = ['file_root', relative_path.to_s]
      "#{PREFIX}:#{CanonicalDigest.new.hexdigest_payload(payload)}"
    end

    def excluded_key?(key)
      name = key.to_s
      EXCLUDED_KEYS.include?(key.to_sym) || name.end_with?('_loc', 'comment', 'comments')
    end
    private_class_method :excluded_key?
  end
end
