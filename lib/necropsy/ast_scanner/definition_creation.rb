# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def add_definition(symbol_id:, kind:, source_node:, context:, defined_via:, owner:, name:,
                       visibility: context.visibility)
      definition_emitter.emit(
        symbol_id: symbol_id,
        kind: kind,
        source_node: source_node,
        context: context,
        defined_via: defined_via,
        owner: owner,
        name: name,
        visibility: visibility
      )
    end
  end
end
