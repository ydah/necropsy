# frozen_string_literal: true

require 'json'
require 'yaml'

module Necropsy
  module ArtifactLoader
    module_function

    def load(path, label: 'Artifact')
      contents = File.read(File.expand_path(path))
      JSON.parse(contents)
    rescue JSON::ParserError
      begin
        YAML.safe_load(contents, aliases: false)
      rescue Psych::Exception, ArgumentError, TypeError => e
        raise Error, "Could not read #{label.downcase} #{path}: #{e.message}"
      end
    rescue SystemCallError, ArgumentError, TypeError, Psych::Exception => e
      raise Error, "Could not read #{label.downcase} #{path}: #{e.message}"
    end

    def load_mapping(path, label: 'Artifact')
      value = load(path, label: label)
      return value if value.is_a?(Hash)

      raise Error, "#{label} must contain a mapping"
    end
  end
end
