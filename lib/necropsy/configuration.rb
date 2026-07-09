# frozen_string_literal: true

require 'yaml'

module Necropsy
  class Configuration
    DEFAULT_FAIL_ON = :high
    DEFAULT_BASELINE = '.necropsy_baseline.yml'

    attr_reader :root, :path, :data

    def self.load(root:, path: nil)
      config_path = path ? File.expand_path(path, root) : File.join(root, '.necropsy.yml')
      data = File.exist?(config_path) ? YAML.load_file(config_path) : {}
      new(root: root, path: config_path, data: data || {})
    end

    def initialize(root:, path:, data:)
      @root = File.expand_path(root)
      @path = path
      @data = stringify_keys(data)
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
      (fetch('ci', 'fail_on') || DEFAULT_FAIL_ON).to_sym
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
      fetch('cache', 'path') || '.necropsy_cache/scan.yml'
    end

    def scan_cache_key
      data.except('cache')
    end

    def factory_methods
      Array(fetch('rta', 'factory_methods') || %w[build create build_stubbed]).map(&:to_s)
    end

    private

    def fetch(*keys)
      keys.reduce(data) do |current, key|
        break nil unless current.is_a?(Hash)

        current[key.to_s]
      end
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
  end
end
