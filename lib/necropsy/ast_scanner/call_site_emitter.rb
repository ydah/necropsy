# frozen_string_literal: true

module Necropsy
  class AstScanner
    # Owns deterministic call-site identity allocation and append semantics.
    class CallSiteEmitter
      def initialize(state:)
        @state = state
      end

      def emit(source_node:, context:, role:, message:, receiver_kind:, receiver_name: nil,
               caller_id: context.current_caller_id, dynamic: false, metadata: {}, append: false)
        structural_digest = DefinitionIdentity.body_digest(source_node)
        ordinal_key = [caller_id, context.relative_file, role.to_sym, message.to_s, structural_digest]
        ordinal = @state.call_site_ordinals[ordinal_key] += 1
        site = CallSite.new(
          call_site_id: CallSiteIdentity.source_id(
            caller_definition_id: caller_id,
            relative_path: context.relative_file,
            role: role,
            message: message,
            structural_digest: structural_digest,
            ordinal: ordinal
          ),
          caller_id: caller_id,
          message: message.to_s,
          receiver_kind: receiver_kind,
          receiver_name: receiver_name,
          file: context.relative_file,
          line: source_node.location.start_line,
          test: context.test,
          dynamic: dynamic,
          metadata: metadata
        )
        append(site) if append
        site
      end

      def append(site)
        @state.call_sites << site
      end

      def derive(site, derivation:, caller_id: site.caller_id, message: site.message, metadata: {})
        site.with(
          call_site_id: CallSiteIdentity.derived_id(
            parent_call_site_id: site.call_site_id,
            derivation: derivation,
            caller_definition_id: caller_id,
            message: message
          ),
          caller_id: caller_id,
          message: message.to_s,
          metadata: site.metadata.merge(
            'derived_from_call_site_id' => site.call_site_id,
            'derived_via' => derivation.to_s
          ).merge(metadata)
        )
      end
    end
  end
end
