# frozen_string_literal: true

require 'prism'

module Necropsy
  module EmbeddedRuby
    TAG_PATTERN = /<%(?![%#])[-=]?(.*?)-?%>/m

    module_function

    def extract(source)
      cursor = 0
      output = +''
      source.to_enum(:scan, TAG_PATTERN).each do
        match = Regexp.last_match
        output << blank(source[cursor...match.begin(0)])
        output << strip_ruby_comments(match[1])
        cursor = match.end(0)
      end
      output << blank(source[cursor..])
      output
    end

    def call_names(source)
      result = Prism.parse(extract(source))
      return Set.new if result.failure?

      names = Set.new
      pending = [result.value]
      until pending.empty?
        node = pending.pop
        names << node.name.to_s if node.is_a?(Prism::CallNode) && node.name
        pending.concat(node.child_nodes.compact)
      end
      names
    end

    def blank(source)
      source.to_s.gsub(/[^\n]/, ' ')
    end
    private_class_method :blank

    def strip_ruby_comments(source)
      bytes = source.bytes
      Prism.parse(source).comments.each do |comment|
        location = comment.location
        (location.start_offset...location.end_offset).each do |offset|
          bytes[offset] = 32 unless bytes[offset] == 10
        end
      end
      bytes.pack('C*').force_encoding(source.encoding)
    end
    private_class_method :strip_ruby_comments
  end
end
