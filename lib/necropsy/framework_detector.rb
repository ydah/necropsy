# frozen_string_literal: true

require 'pathname'
require 'prism'

module Necropsy
  class FrameworkDetector
    FRAMEWORK_GEMS = {
      'rails' => 'rails',
      'rubocop' => 'rubocop',
      'sidekiq' => 'sidekiq',
      'graphql' => 'graphql',
      'view_component' => 'view_component',
      'active_model_serializers' => 'active_model_serializers',
      'blueprinter' => 'blueprinter'
    }.freeze
    DEPENDENCY_DECLARATION_METHODS = %i[gem add_dependency add_runtime_dependency add_development_dependency].freeze

    def initialize(root:)
      @root = File.expand_path(root)
    end

    def detect(reference_files)
      dependency_files = Array(reference_files).select { |file| dependency_file?(file) }
      dependencies = dependency_files.flat_map { |file| dependency_names(file) }.to_set
      FRAMEWORK_GEMS.filter_map { |gem_name, framework| framework if dependencies.include?(gem_name) }.sort
    end

    private

    attr_reader :root

    def dependency_file?(file)
      relative = relative_path(file)
      %w[Gemfile Gemfile.lock].include?(relative) || relative.end_with?('.gemspec')
    end

    def dependency_names(file)
      source = File.read(file)
      return locked_dependency_names(source) if File.basename(file) == 'Gemfile.lock'

      ruby_dependency_names(source)
    rescue SystemCallError, EncodingError
      []
    end

    def locked_dependency_names(source)
      source.each_line.filter_map { |line| line[/\A    ([A-Za-z0-9_.-]+) \(/, 1] }
    end

    def ruby_dependency_names(source)
      result = Prism.parse(source)
      return [] if result.failure?

      pending = [result.value]
      names = []
      until pending.empty?
        node = pending.pop
        if node.is_a?(Prism::CallNode) && DEPENDENCY_DECLARATION_METHODS.include?(node.name)
          argument = Array(node.arguments&.arguments).first
          names << argument.content if argument.is_a?(Prism::StringNode)
        end
        pending.concat(node.child_nodes.compact)
      end
      names
    end

    def relative_path(file)
      Pathname.new(File.expand_path(file)).relative_path_from(Pathname.new(root)).to_s
    rescue ArgumentError
      file.to_s
    end
  end
end
