# frozen_string_literal: true

require 'fileutils'
require 'json'

module Necropsy
  # Compares positive runtime target observations with the static target set.
  #
  # Runtime observations may discover a target that the static resolver did not
  # enumerate.  That is a safety signal and a useful regression fixture, but an
  # unobserved static target is never removed from the model.
  class RuntimeFeedback
    SCHEMA_VERSION = 1
    DEFAULT_FIXTURE_LIMIT = 32

    def initialize(static_targets:, observed_targets:, max_fixtures: DEFAULT_FIXTURE_LIMIT)
      @static_targets = normalize_static_targets(static_targets)
      @observed_targets = normalize_observed_targets(observed_targets)
      @max_fixtures = Integer(max_fixtures)
      raise ArgumentError, 'max_fixtures must be non-negative' if @max_fixtures.negative?
    rescue ArgumentError, TypeError => e
      raise e unless e.message.start_with?('invalid value for Integer()', 'no implicit conversion of')

      raise ArgumentError, 'max_fixtures must be a non-negative integer'
    end

    def call
      observed_by_site = @observed_targets.group_by { |target| target.fetch('call_site_id') }
      static_by_site = @static_targets
      missing_static = @observed_targets.filter_map do |target|
        static = static_by_site.fetch(target.fetch('call_site_id'), [])
        next if static.include?(target.fetch('target_definition_id'))

        target.merge(
          'classification' => 'missing_static_target',
          'safety' => 'safety_bug'
        )
      end
      fixtures = missing_static.first(@max_fixtures).map { |target| fixture_candidate(target) }
      unobserved_static = static_by_site.flat_map do |call_site_id, targets|
        observed = observed_by_site.fetch(call_site_id, []).map { |target| target.fetch('target_definition_id') }
        targets.reject { |target| observed.include?(target) }.map do |target|
          { 'call_site_id' => call_site_id, 'target_definition_id' => target, 'informational' => true }
        end
      end

      {
        'schema_version' => SCHEMA_VERSION,
        'policy' => 'positive_only',
        'comparison' => {
          'call_sites' => (static_by_site.keys | observed_by_site.keys).length,
          'static_target_count' => static_by_site.values.sum(&:length),
          'observed_target_count' => @observed_targets.length
        },
        'missing_static_targets' => missing_static,
        'unexpected_targets' => missing_static,
        'unobserved_static_targets' => unobserved_static,
        'fixture_candidates' => fixtures,
        'fixture_exported' => false
      }
    end

    def write_fixture_candidates(path)
      payload = call
      candidates = payload.fetch('fixture_candidates')
      destination = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(temporary, "#{JSON.pretty_generate(candidates)}\n")
      File.rename(temporary, destination)
      payload.merge('fixture_exported' => true, 'fixture_path' => destination)
    rescue SystemCallError => e
      raise Error, "Could not export runtime feedback fixtures: #{e.message}"
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def self.from_graph(graph, observed_targets:, max_fixtures: DEFAULT_FIXTURE_LIMIT)
      static_targets = graph.resolution_records.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |record, result|
        result[record.resolution.call_site_id].concat(record.resolution.target_definition_ids)
      end
      new(static_targets: static_targets, observed_targets: observed_targets, max_fixtures: max_fixtures)
    end

    private

    def normalize_static_targets(value)
      raise ArgumentError, 'static_targets must be a Hash' unless value.is_a?(Hash)

      value.each_with_object({}) do |(call_site_id, targets), result|
        site = identifier(call_site_id, 'call_site_id')
        result[site] = Array(targets).map { |target| identifier(target, 'target_definition_id') }.uniq.sort
      end.sort.to_h.freeze
    end

    def normalize_observed_targets(value)
      Array(value).map do |target|
        raise ArgumentError, 'observed target must be a Hash' unless target.is_a?(Hash)

        data = target.to_h { |key, item| [key.to_s, item] }
        call_site_id = identifier(data['call_site_id'], 'call_site_id')
        target_definition_id = identifier(
          data['target_definition_id'] || data['target_id'], 'target_definition_id'
        )
        normalized = {
          'call_site_id' => call_site_id,
          'target_definition_id' => target_definition_id
        }
        %w[receiver_class file line].each do |key|
          normalized[key] = data[key] unless data[key].nil?
        end
        normalized
      end.uniq.sort_by { |target| [target['call_site_id'], target['target_definition_id']] }.freeze
    end

    def fixture_candidate(target)
      {
        'call_site_id' => target.fetch('call_site_id'),
        'target_definition_id' => target.fetch('target_definition_id'),
        'receiver_class' => target['receiver_class'],
        'source' => {
          'file' => target['file'],
          'line' => target['line']
        }.compact,
        'reason' => 'runtime target was not present in the static target set'
      }.compact
    end

    def identifier(value, field)
      normalized = value.to_s
      raise ArgumentError, "#{field} must not be empty" if normalized.empty?

      normalized
    end
  end
end
