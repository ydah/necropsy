# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def scanned_call_site(source_node:, context:, role:, message:, receiver_kind:, receiver_name: nil,
                          caller_id: context.current_caller_id, dynamic: false, metadata: {})
      call_site_emitter.emit(
        source_node: source_node,
        context: context,
        role: role,
        message: message,
        receiver_kind: receiver_kind,
        receiver_name: receiver_name,
        caller_id: caller_id,
        dynamic: dynamic,
        metadata: metadata
      )
    end

    def add_scanned_call_site(**attributes)
      call_site_emitter.append(scanned_call_site(**attributes))
    end

    def derived_call_site(site, derivation:, caller_id: site.caller_id, message: site.message, metadata: {})
      call_site_emitter.derive(site, derivation: derivation, caller_id: caller_id, message: message, metadata: metadata)
    end
  end
end
