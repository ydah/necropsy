# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def add_definition(symbol_id:, kind:, source_node:, context:, defined_via:, owner:, name:,
                       visibility: context.visibility)
      body_digest = DefinitionIdentity.body_digest(source_node)
      ordinal_key = [kind, symbol_id, context.relative_file, body_digest]
      ordinal = definition_ordinals[ordinal_key] += 1
      definition = Node.new(
        id: symbol_id,
        symbol_id: symbol_id,
        definition_id: DefinitionIdentity.definition_id(
          kind: kind,
          symbol_id: symbol_id,
          relative_path: context.relative_file,
          body_digest: body_digest,
          ordinal: ordinal
        ),
        body_digest: body_digest,
        ordinal: ordinal,
        kind: kind,
        file: context.relative_file,
        line: source_node.location.start_line,
        end_line: source_node.location.end_line,
        defined_via: defined_via,
        owner: owner,
        name: name.to_s,
        test: context.test,
        visibility: visibility
      )
      nodes << definition
      definition
    end
  end
end
