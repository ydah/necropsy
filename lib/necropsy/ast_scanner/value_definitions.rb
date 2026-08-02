# frozen_string_literal: true

module Necropsy
  class AstScanner
    private

    def visit_constant_write(node, context)
      return visit_children(node, context) unless struct_or_data_definition?(node.value)

      owner = qualify_constant(node.name.to_s, context.namespace)
      data = class_record(owner)
      data[:kind] = :class
      data[:file] = context.relative_file
      data[:line] = node.location.start_line
      instantiated_classes << owner

      symbol_arguments(node.value).each do |name|
        nodes << Node.new(
          id: "#{owner}##{name}",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: node.value.name == :define ? :data_define : :struct_new,
          owner: owner,
          name: name,
          test: context.test,
          visibility: :public
        )
        next if node.value.name == :define

        nodes << Node.new(
          id: "#{owner}##{name}=",
          kind: :instance_method,
          file: context.relative_file,
          line: node.location.start_line,
          end_line: node.location.end_line,
          defined_via: :struct_new,
          owner: owner,
          name: "#{name}=",
          test: context.test,
          visibility: :public
        )
      end

      return unless node.value.block

      block_context = context.dup
      block_context.namespace = owner
      block_context.owner = owner
      block_context.singleton_scope = false
      block_context.visibility = :public
      block_context.module_function = false
      visit(node.value.block.body, block_context)
    end

    def struct_or_data_definition?(value)
      return false unless value.is_a?(Prism::CallNode)

      receiver_name = constant_name(value.receiver)
      (receiver_name == 'Struct' && value.name == :new) || (receiver_name == 'Data' && value.name == :define)
    end

    def visit_children(node, context)
      node.child_nodes.compact.each { |child| visit(child, context) }
    end
  end
end
