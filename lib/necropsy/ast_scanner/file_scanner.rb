# frozen_string_literal: true

module Necropsy
  class AstScanner
    # Coordinates the lifecycle of one source file. AST semantics remain in
    # AstScanner; this object owns reading, parsing, root-definition creation,
    # status recording, and handing the parsed tree to the visitor.
    class FileScanner
      def initialize(project:, file:, state:, definition_emitter:, flow_result:, visit:,
                     record_parse_errors:, record_source_failure:)
        @project = project
        @file = file
        @state = state
        @definition_emitter = definition_emitter
        @flow_result = flow_result
        @visit = visit
        @record_parse_errors = record_parse_errors
        @record_source_failure = record_source_failure
        @root_id = nil
      end

      def scan
        @root_id = nil
        relative = @project.relative_path(@file)
        context = initial_context(relative)
        result = Prism.parse(File.read(@file))
        root = emit_root(result.value, context)
        @root_id = root.graph_id
        context.current_caller_id = root.graph_id
        context.root_id = root.graph_id
        context.flow_result = @flow_result.call(result.value, context)
        record_status(root.graph_id, relative, result)
        @visit.call(result.value, context)
      rescue DefinitionIdentity::CanonicalizationError, SystemStackError, SystemCallError, EncodingError => e
        @record_source_failure.call(@root_id || "file:#{relative}", relative, e)
      end

      private

      def initial_context(relative)
        AstScanner::Context.new(
          namespace: nil,
          lexical_nesting: [],
          owner: nil,
          current_caller_id: nil,
          current_method_name: nil,
          current_kind: :block_entry,
          root_id: nil,
          file: @file,
          relative_file: relative,
          test: @project.test_file?(@file),
          singleton_scope: false,
          visibility: :public,
          module_function: false,
          static_ancestry: true,
          flow_result: nil
        )
      end

      def emit_root(source, context)
        @definition_emitter.emit(
          symbol_id: "file:#{context.relative_file}",
          kind: :block_entry,
          source_node: source,
          context: context,
          defined_via: :file,
          owner: nil,
          name: context.relative_file,
          visibility: :public
        )
      end

      def record_status(root_id, relative, result)
        if result.failure?
          @state.file_statuses[relative] = :recovered
          @record_parse_errors.call(root_id, relative, result)
        else
          @state.file_statuses[relative] = :complete
        end
      end
    end
  end
end
