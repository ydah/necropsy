# frozen_string_literal: true

module Necropsy
  module Analyzers
    module Dynamic
      module RuntimeReference
        module_function

        def build(symbol_id:, file: nil, line: nil, definition_id: nil)
          {
            'definition_id' => definition_id,
            'symbol_id' => symbol_id,
            'file' => file,
            'line' => line
          }.compact
        end

        def normalize(value)
          return value if value.is_a?(String)
          return unless value.is_a?(Hash)

          data = value.to_h { |key, item| [key.to_s, item] }
          symbol_id = data['symbol_id']
          return unless symbol_id.is_a?(String) && !symbol_id.empty?
          return unless valid_optional_string?(data, 'definition_id') && valid_optional_string?(data, 'file')

          line = normalize_line(data['line'])
          return if data.key?('line') && !data['line'].nil? && line.nil?

          build(
            definition_id: optional_string(data['definition_id']),
            symbol_id: symbol_id,
            file: optional_string(data['file']),
            line: line
          )
        end

        def sort_key(reference)
          normalized = normalize(reference)
          return ['', reference.to_s, '', 0] unless normalized.is_a?(Hash)

          [
            normalized.fetch('definition_id', ''),
            normalized.fetch('symbol_id'),
            normalized.fetch('file', ''),
            normalized.fetch('line', 0)
          ]
        end

        def key(reference)
          sort_key(reference)
        end

        def preferred(structured:, legacy:)
          return Array(legacy) if structured.nil?

          structured_values = Array(structured)
          structured_symbols = structured_values.filter_map do |reference|
            normalize(reference).then { |normalized| normalized['symbol_id'] if normalized.is_a?(Hash) }
          end.to_set
          structured_values + Array(legacy).reject { |symbol_id| structured_symbols.include?(symbol_id) }
        end

        def malformed?(reference)
          !reference.is_a?(String) && normalize(reference).nil?
        end

        def relative_file(root, path)
          expanded = File.expand_path(path)
          prefix = "#{File.expand_path(root)}/"
          return unless expanded.start_with?(prefix)

          expanded.delete_prefix(prefix)
        end

        def optional_string(value)
          value if value.is_a?(String) && !value.empty?
        end
        private_class_method :optional_string

        def valid_optional_string?(data, key)
          !data.key?(key) || data[key].nil? || (data[key].is_a?(String) && !data[key].empty?)
        end
        private_class_method :valid_optional_string?

        def normalize_line(value)
          return if value.nil?

          line = Integer(value, exception: false)
          line if line&.positive?
        end
        private_class_method :normalize_line
      end
    end
  end
end
