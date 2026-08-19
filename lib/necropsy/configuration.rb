# frozen_string_literal: true

require 'yaml'

module Necropsy
  class Configuration
    DEFAULT_FAIL_ON = :new_review_candidate
    CI_ACTIONABILITY_THRESHOLDS = %i[new_review_candidate new_verified_candidate].freeze
    DEFAULT_BASELINE = '.necropsy_baseline.yml'
    RTA_PRUNING_MODES = %w[rank_only legacy].freeze
    STATIC_ANALYZER_ORDER = %w[name_resolution cha rta].freeze
    QUARANTINE_EXPIRY_POLICIES = %w[warn fail ignore].freeze
    WORLD_MODES = %w[application library].freeze
    LOAD_ROOT_POLICIES = %w[known all].freeze
    TOP_LEVEL_KEYS = %w[
      analysis analyzers frameworks entry_points ci quarantine bench cache rta resolution paths report logging
      implicit_callers
    ].freeze
    NESTED_KEYS = {
      'analysis' => %w[world load_roots],
      'analyzers' => %w[static dynamic custom],
      'analyzers.dynamic' => %w[coverage coverband trace_point],
      'entry_points' => %w[extra],
      'ci' => %w[baseline fail_on],
      'quarantine' => %w[days expiry],
      'bench' => %w[precision_threshold recall_threshold],
      'cache' => %w[enabled path],
      'rta' => %w[factory_methods pruning],
      'resolution' => %w[ambiguity_limit],
      'paths' => %w[analyze reference test include exclude],
      'report' => %w[include exclude],
      'logging' => %w[verbose]
    }.freeze
    DYNAMIC_KEYS = %w[source min_observation_days expected_source_revision keys key pattern connect_timeout read_timeout].freeze
    IMPLICIT_CALLER_KEYS = %w[name_pattern owner_ancestors reason].freeze
    CUSTOM_ANALYZER_KEYS = %w[class require trusted].freeze

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

    def world
      configured = fetch('analysis', 'world')
      mode = configured.nil? ? 'application' : configured.to_s
      return mode.to_sym if WORLD_MODES.include?(mode)

      raise Error, "analysis.world must be one of: #{WORLD_MODES.join(', ')}"
    end

    def library_world?
      world == :library
    end

    def load_roots
      configured = fetch('analysis', 'load_roots')
      policy = configured.nil? ? 'known' : configured.to_s
      return policy.to_sym if LOAD_ROOT_POLICIES.include?(policy)

      raise Error, "analysis.load_roots must be one of: #{LOAD_ROOT_POLICIES.join(', ')}"
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

    def frameworks(detected_frameworks: [])
      (Array(data['frameworks']).map(&:to_s) + Array(detected_frameworks).map(&:to_s)).uniq.sort.freeze
    end

    def rails_enabled?(detected_frameworks: [])
      frameworks(detected_frameworks: detected_frameworks).include?('rails')
    end

    def baseline_path
      fetch('ci', 'baseline') || DEFAULT_BASELINE
    end

    def fail_on
      level = (fetch('ci', 'fail_on') || DEFAULT_FAIL_ON).to_sym
      return level if CONFIDENCE_LEVELS.key?(level) || CI_ACTIONABILITY_THRESHOLDS.include?(level)

      allowed = (CONFIDENCE_LEVELS.keys + CI_ACTIONABILITY_THRESHOLDS).join(', ')
      raise Error, "Invalid ci.fail_on threshold: #{level}; expected one of: #{allowed}"
    end

    def fail_on_actionability?
      CI_ACTIONABILITY_THRESHOLDS.include?(fail_on)
    end

    def fail_on_actionability
      case fail_on
      when :new_review_candidate then :review_candidate
      when :new_verified_candidate then :verified_candidate
      end
    end

    def min_observation_days
      coverage_days = fetch('analyzers', 'dynamic', 'coverage', 'min_observation_days')
      coverband_days = fetch('analyzers', 'dynamic', 'coverband', 'min_observation_days')
      Integer(coverage_days || coverband_days || 30)
    end

    REMOTE_DYNAMIC_KEYS = %w[
      total_timeout max_response_bytes max_bulk_bytes max_array_elements max_resp_depth max_keys max_payload_depth
    ].freeze
    DYNAMIC_TIMEOUT_KEYS = %w[connect_timeout read_timeout total_timeout].freeze
    DYNAMIC_LIMIT_KEYS = (REMOTE_DYNAMIC_KEYS - %w[total_timeout]).freeze

    def quarantine_days
      Integer(fetch('quarantine', 'days') || 30)
    end

    def quarantine_expiry
      configured = fetch('quarantine', 'expiry')
      policy = configured.nil? ? 'warn' : configured.to_s
      return policy.to_sym if QUARANTINE_EXPIRY_POLICIES.include?(policy)

      raise Error, "quarantine.expiry must be one of: #{QUARANTINE_EXPIRY_POLICIES.join(', ')}"
    end

    def bench_precision_threshold
      Float(fetch('bench', 'precision_threshold') || 0.85)
    end

    def bench_recall_threshold
      value = fetch('bench', 'recall_threshold')
      value && Float(value)
    end

    def cache_enabled?
      value = fetch('cache', 'enabled')
      value.nil? || value != false
    end

    def cache_path
      fetch('cache', 'path') || '.necropsy_cache/scan.json'
    end

    def scan_cache_key
      data.except('cache', 'report')
    end

    def factory_methods
      Array(fetch('rta', 'factory_methods') || %w[build create build_stubbed]).map(&:to_s)
    end

    def rta_pruning
      configured = fetch('rta', 'pruning')
      mode = configured.nil? ? 'rank_only' : configured.to_s
      return mode.to_sym if RTA_PRUNING_MODES.include?(mode)

      raise Error, "rta.pruning must be one of: #{RTA_PRUNING_MODES.join(', ')}"
    end

    def ambiguity_limit
      value = fetch('resolution', 'ambiguity_limit')
      return 4 if value.nil?
      return Float::INFINITY if value.to_s == 'unlimited'

      limit = Integer(value)
      return limit if limit.positive?

      raise Error, 'resolution.ambiguity_limit must be a positive integer or unlimited'
    rescue ArgumentError, TypeError
      raise Error, 'resolution.ambiguity_limit must be a positive integer or unlimited'
    end

    def analyze_paths
      configured = fetch('paths', 'analyze')
      configured = fetch('paths', 'include') if configured.nil?
      Array(configured).map(&:to_s)
    end

    def reference_paths
      configured = fetch('paths', 'reference')
      Array(configured.nil? ? ['**/*'] : configured).map(&:to_s)
    end

    def test_paths
      configured = fetch('paths', 'test')
      Array(configured.nil? ? %w[spec/** test/**] : configured).map(&:to_s)
    end

    def include_paths
      analyze_paths
    end

    def legacy_include_paths?
      !fetch('paths', 'include').nil? && fetch('paths', 'analyze').nil?
    end

    def exclude_paths
      Array(fetch('paths', 'exclude')).map(&:to_s)
    end

    def report_include_paths
      Array(fetch('report', 'include')).map(&:to_s)
    end

    def report_exclude_paths
      Array(fetch('report', 'exclude')).map(&:to_s)
    end

    def implicit_callers
      @implicit_callers ||= Array(data['implicit_callers']).map do |entry|
        {
          name_pattern: Regexp.new(entry.fetch('name_pattern')),
          owner_ancestors: Array(entry['owner_ancestors']).map(&:to_s),
          reason: entry['reason']&.to_s
        }
      end
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
        next unless value

        validate_hash_keys(value, DYNAMIC_KEYS + REMOTE_DYNAMIC_KEYS, "analyzers.dynamic.#{name}")
        validate_dynamic_limits!(value, name)
      end
      validate_custom_analyzers!
      validate_implicit_callers!
      world
      load_roots
      rta_pruning
      ambiguity_limit
      quarantine_expiry
      validate_numeric_ranges!
      validate_static_analyzers!
    end

    def validate_hash_keys(value, allowed, location)
      raise Error, "#{location} must be a mapping" unless value.is_a?(Hash)

      unknown = value.keys - allowed
      return if unknown.empty?

      raise Error, "Unknown #{location} option#{'s' if unknown.length > 1}: #{unknown.join(', ')}"
    end

    def validate_dynamic_limits!(value, name)
      DYNAMIC_TIMEOUT_KEYS.each do |key|
        next unless value.key?(key)

        parsed = Float(value[key])
        dynamic_limit_error!(name, key) unless parsed.positive? && parsed.finite?
      rescue ArgumentError, TypeError
        dynamic_limit_error!(name, key)
      end
      DYNAMIC_LIMIT_KEYS.each do |key|
        next unless value.key?(key)

        dynamic_limit_error!(name, key) unless Integer(value[key]).positive?
      rescue ArgumentError, TypeError
        dynamic_limit_error!(name, key)
      end
    end

    def validate_numeric_ranges!
      validate_unit_interval!('bench.precision_threshold', bench_precision_threshold)
      recall = bench_recall_threshold
      validate_unit_interval!('bench.recall_threshold', recall) if recall
      validate_positive_integer!('quarantine.days', fetch('quarantine', 'days') || 30)
      %w[coverage coverband trace_point].each do |name|
        value = fetch('analyzers', 'dynamic', name, 'min_observation_days')
        validate_positive_integer!("analyzers.dynamic.#{name}.min_observation_days", value) unless value.nil?
      end
    rescue ArgumentError, TypeError
      raise Error, 'Numeric configuration values must use their documented finite ranges'
    end

    def validate_unit_interval!(name, value)
      raise Error, "#{name} must be a finite number between 0 and 1" unless value.finite? && value.between?(0.0, 1.0)
    end

    def validate_positive_integer!(name, value)
      valid_form = value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\+?\d+\z/))
      raise Error, "#{name} must be a positive integer" unless valid_form

      parsed = Integer(value)
      raise Error, "#{name} must be a positive integer" unless parsed.positive?
    rescue ArgumentError, TypeError
      raise Error, "#{name} must be a positive integer"
    end

    def validate_static_analyzers!
      configured = static_analyzers
      duplicates = configured.tally.select { |_name, count| count > 1 }.keys
      raise Error, "Duplicate static analyzers: #{duplicates.sort.join(', ')}" if duplicates.any?

      unknown = configured - STATIC_ANALYZER_ORDER
      raise Error, "Unknown static analyzer: #{unknown.first}" if unknown.any?

      positions = configured.map { |name| STATIC_ANALYZER_ORDER.index(name) }
      raise Error, 'Static analyzers must run in name_resolution, cha, rta dependency order' unless positions == positions.sort
    end

    def dynamic_limit_error!(name, key)
      raise Error, "analyzers.dynamic.#{name}.#{key} must be a finite positive number"
    end

    def validate_custom_analyzers!
      custom_analyzers.each do |entry|
        raise Error, 'Each custom analyzer must be a mapping with class and trusted: true' unless entry.is_a?(Hash)

        validate_hash_keys(entry, CUSTOM_ANALYZER_KEYS, 'custom analyzer')
        raise Error, 'Custom analyzer mapping requires class' unless entry['class']
        raise Error, 'Custom analyzer execution requires trusted: true' unless entry['trusted'] == true
      end
    end

    def validate_implicit_callers!
      Array(data['implicit_callers']).each do |entry|
        raise Error, 'Each implicit caller must be a mapping' unless entry.is_a?(Hash)

        validate_hash_keys(entry, IMPLICIT_CALLER_KEYS, 'implicit caller')
        pattern = entry['name_pattern']
        raise Error, 'Implicit caller requires name_pattern' unless pattern.is_a?(String)

        Regexp.new(pattern)
      rescue RegexpError => e
        raise Error, "Invalid implicit caller name_pattern: #{e.message}"
      end
    end
  end
end
