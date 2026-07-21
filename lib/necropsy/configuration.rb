# frozen_string_literal: true

require 'yaml'

module Necropsy
  class Configuration
    DEFAULT_FAIL_ON = :high
    DEFAULT_BASELINE = '.necropsy_baseline.yml'
    TOP_LEVEL_KEYS = %w[analyzers frameworks entry_points ci quarantine bench cache rta paths logging].freeze
    NESTED_KEYS = {
      'analyzers' => %w[static dynamic custom],
      'analyzers.dynamic' => %w[coverage coverband trace_point],
      'entry_points' => %w[extra],
      'ci' => %w[baseline fail_on],
      'quarantine' => %w[days],
      'bench' => %w[precision_threshold recall_threshold],
      'cache' => %w[enabled path],
      'rta' => %w[factory_methods],
      'paths' => %w[include exclude],
      'logging' => %w[verbose]
    }.freeze
    DYNAMIC_KEYS = %w[source min_observation_days keys key pattern connect_timeout read_timeout].freeze

    attr_reader :root, :path, :data

    def self.load(root:, path: nil)
      config_path = path ? File.expand_path(path, root) : File.join(root, '.necropsy.yml')
      data = File.exist?(config_path) ? YAML.safe_load_file(config_path, permitted_classes: [Symbol], aliases: true) : {}
      new(root: root, path: config_path, data: data || {})
    rescue Psych::Exception => e
      raise Error, "Could not parse configuration #{config_path}: #{e.message}"
    end

    def initialize(root:, path:, data:)
      @root = File.expand_path(root)
      @path = path
      @data = stringify_keys(data)
      validate!
    end

    def static_analyzers
      Array(fetch('analyzers', 'static') || %w[name_resolution cha rta]).map(&:to_s)
    end

    def dynamic_config(name)
      fetch('analyzers', 'dynamic', name.to_s) || {}
    end

    def custom_analyzers
      Array(fetch('analyzers', 'custom')).compact
    end

    def entry_point_patterns
      Array(fetch('entry_points', 'extra')).compact.map(&:to_s)
    end

    def frameworks
      Array(data['frameworks']).map(&:to_s)
    end

    def rails_enabled?
      return true if frameworks.include?('rails')

      gemfiles = [File.join(root, 'Gemfile.lock'), File.join(root, 'Gemfile')]
      gemfiles.any? { |file| File.exist?(file) && File.read(file).match?(/(?:^|\s)rails(?:\s|\z|,)/) }
    end

    def baseline_path
      fetch('ci', 'baseline') || DEFAULT_BASELINE
    end

    def fail_on
      level = (fetch('ci', 'fail_on') || DEFAULT_FAIL_ON).to_sym
      return level if CONFIDENCE_LEVELS.key?(level)

      raise Error, "Invalid ci.fail_on confidence level: #{level}"
    end

    def min_observation_days
      coverage_days = fetch('analyzers', 'dynamic', 'coverage', 'min_observation_days')
      coverband_days = fetch('analyzers', 'dynamic', 'coverband', 'min_observation_days')
      (coverage_days || coverband_days || 30).to_i
    end

    def quarantine_days
      (fetch('quarantine', 'days') || 30).to_i
    end

    def bench_precision_threshold
      (fetch('bench', 'precision_threshold') || 0.85).to_f
    end

    def bench_recall_threshold
      value = fetch('bench', 'recall_threshold')
      value&.to_f
    end

    def cache_enabled?
      value = fetch('cache', 'enabled')
      value.nil? || value != false
    end

    def cache_path
      fetch('cache', 'path') || '.necropsy_cache/scan.json'
    end

    def scan_cache_key
      data.except('cache')
    end

    def factory_methods
      Array(fetch('rta', 'factory_methods') || %w[build create build_stubbed]).map(&:to_s)
    end

    def include_paths
      Array(fetch('paths', 'include')).map(&:to_s)
    end

    def exclude_paths
      Array(fetch('paths', 'exclude')).map(&:to_s)
    end

    def verbose?
      fetch('logging', 'verbose') == true
    end

    private

    def fetch(*keys)
      current = data
      keys.each do |key|
        return nil unless current.is_a?(Hash)

        current = current[key.to_s]
      end
      current
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), memo| memo[key.to_s] = stringify_keys(child) }
      when Array
        value.map { |child| stringify_keys(child) }
      else
        value
      end
    end

    def validate!
      validate_hash_keys(data, TOP_LEVEL_KEYS, 'configuration')
      NESTED_KEYS.each do |path, allowed|
        value = fetch(*path.split('.'))
        validate_hash_keys(value, allowed, path) if value
      end
      %w[coverage coverband trace_point].each do |name|
        value = fetch('analyzers', 'dynamic', name)
        validate_hash_keys(value, DYNAMIC_KEYS, "analyzers.dynamic.#{name}") if value
      end
      validate_custom_analyzers!
    end

    def validate_hash_keys(value, allowed, location)
      raise Error, "#{location} must be a mapping" unless value.is_a?(Hash)

      unknown = value.keys - allowed
      return if unknown.empty?

      raise Error, "Unknown #{location} option#{'s' if unknown.length > 1}: #{unknown.join(', ')}"
    end

    def validate_custom_analyzers!
      custom_analyzers.each do |entry|
        next if entry.is_a?(String)
        raise Error, 'Each custom analyzer must be a class name or a mapping with class and require' unless entry.is_a?(Hash)

        validate_hash_keys(entry, %w[class require], 'custom analyzer')
        raise Error, 'Custom analyzer mapping requires class' unless entry['class']
      end
    end
  end
end
