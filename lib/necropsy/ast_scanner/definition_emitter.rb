# frozen_string_literal: true

module Necropsy
  class AstScanner
    # Owns the identity and append semantics for definitions discovered during
    # a scan. The scanner supplies the current context; this object owns the
    # mutable definition ledger and does not need to know how nodes are visited.
    class DefinitionEmitter
      def initialize(state:)
        @state = state
      end

      def emit(symbol_id:, kind:, source_node:, context:, defined_via:, owner:, name:,
               visibility: context.visibility)
        body_digest = DefinitionIdentity.body_digest(source_node)
        ordinal_key = [kind, symbol_id, context.relative_file, body_digest]
        ordinal = @state.definition_ordinals[ordinal_key] += 1
        definition_id = if defined_via == :file
                          DefinitionIdentity.file_root_id(relative_path: context.relative_file)
                        else
                          DefinitionIdentity.definition_id(
                            kind: kind,
                            symbol_id: symbol_id,
                            relative_path: context.relative_file,
                            body_digest: body_digest,
                            ordinal: ordinal
                          )
                        end
        definition = Node.new(
          id: symbol_id,
          symbol_id: symbol_id,
          definition_id: definition_id,
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
        @state.nodes << definition
        definition
      end
    end
  end
end
