# frozen_string_literal: true

require 'digest'

module Necropsy
  class WorldPolicy
    def initialize(graph:, project:)
      @graph = graph
      @project = project
    end

    def apply
      protect_library_surface if config.library_world?
      add_conservative_load_roots if config.load_roots == :all
      record_policy
    end

    private

    attr_reader :graph, :project

    def config
      project.config
    end

    def protect_library_surface
      graph.method_nodes.reject(&:test).select { |node| %i[public protected].include?(node.visibility) }.each do |node|
        graph.add_entry_point(
          node.graph_id,
          :library_public_api,
          domain: :external,
          evidence: {
            'type' => 'world_policy',
            'world' => 'library',
            'visibility' => node.visibility.to_s
          }
        )
        graph.add_blocker(open_public_api_blocker(node))
      end
    end

    def open_public_api_blocker(node)
      Blocker.new(
        kind: :open_public_api,
        scope_kind: :definition,
        scope_value: node.graph_id,
        source: :world_policy,
        reason: 'Library public and protected APIs may have callers outside the repository',
        suggested_action: :review_external_contract,
        metadata: {
          'caller_domain' => 'runtime',
          'root_domain' => 'external',
          'receiver_kind' => 'implicit',
          'world' => 'library',
          'visibility' => node.visibility.to_s
        }
      )
    end

    def add_conservative_load_roots
      graph.nodes.values.select { |node| node.kind == :block_entry && !node.test }.each do |node|
        graph.add_entry_point(
          node.graph_id,
          :production_load_unit,
          domain: :runtime,
          evidence: {
            'type' => 'load_policy',
            'policy' => 'all',
            'file' => node.file
          }
        )
      end
    end

    def record_policy
      graph.observation['world_policy'] = {
        'world' => config.world.to_s,
        'load_roots' => config.load_roots.to_s,
        'configuration_sha256' => configuration_digest
      }
    end

    def configuration_digest
      Digest::SHA256.hexdigest(BoundedCanonicalizer.dump(config.scan_cache_key))
    rescue StandardError, SystemStackError
      'unavailable'
    end
  end
end
