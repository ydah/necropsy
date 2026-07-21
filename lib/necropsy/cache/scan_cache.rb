# frozen_string_literal: true

require 'fileutils'
require 'json'

module Necropsy
  module Cache
    class ScanCache
      VERSION = 4

      def initialize(project:)
        @project = project
      end

      def fetch(files)
        return yield unless project.config.cache_enabled?

        metadata = cache_metadata(files)
        cached = read(metadata)
        return cached if cached

        result = yield
        write(metadata, result)
        result
      rescue SystemCallError, JSON::ParserError => e
        warn_cache("Cache unavailable: #{e.message}")
        yield
      end

      private

      attr_reader :project

      def read(metadata)
        payload = load_payload
        return nil unless payload
        return nil unless payload['version'] == VERSION
        return nil unless payload['metadata'] == metadata

        deserialize_scan_result(payload.fetch('scan_result'))
      rescue StandardError => e
        warn_cache("Ignoring invalid cache: #{e.message}")
        nil
      end

      def load_payload
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      end

      def write(metadata, result)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate({
          'version' => VERSION,
          'metadata' => metadata,
          'scan_result' => serialize_scan_result(result)
        }))
      rescue StandardError => e
        warn_cache("Could not write cache: #{e.message}")
        nil
      end

      def path
        @path ||= File.expand_path(project.config.cache_path, project.root)
      end

      def file_metadata(files)
        files.each_with_object({}) do |file, metadata|
          stat = File.stat(file)
          metadata[project.relative_path(file)] = {
            'size' => stat.size,
            'mtime' => "#{stat.mtime.to_i}.#{stat.mtime.nsec}"
          }
        end
      end

      def cache_metadata(files)
        {
          'files' => file_metadata(files),
          'configuration' => project.config.scan_cache_key
        }
      end

      def serialize_scan_result(result)
        {
          'nodes' => result.nodes.map(&:to_h),
          'call_sites' => result.call_sites.map(&:to_h),
          'instantiated_classes' => result.instantiated_classes.to_a.sort,
          'uncertainties' => result.uncertainties.transform_values { |messages| Array(messages).map(&:to_s) },
          'class_infos' => result.class_infos.map(&:to_h),
          'entrypoint_hints' => result.entrypoint_hints.map(&:to_h)
        }
      end

      def deserialize_scan_result(data)
        ScanResult.new(
          nodes: Array(data['nodes']).map { |node| deserialize_node(node) },
          call_sites: Array(data['call_sites']).map { |site| deserialize_call_site(site) },
          instantiated_classes: Set.new(Array(data['instantiated_classes'])),
          uncertainties: deserialize_uncertainties(data['uncertainties']),
          class_infos: Array(data['class_infos']).map { |info| deserialize_class_info(info) },
          entrypoint_hints: Array(data['entrypoint_hints']).map { |entry| deserialize_entry_point(entry) }
        )
      end

      def deserialize_node(data)
        Node.new(
          id: data['id'],
          kind: data['kind'].to_sym,
          file: data['file'],
          line: data['line'].to_i,
          end_line: data['end_line'].to_i,
          defined_via: data['defined_via'].to_sym,
          owner: data['owner'],
          name: data['name'],
          test: data['test'],
          visibility: (data['visibility'] || 'public').to_sym
        )
      end

      def deserialize_call_site(data)
        CallSite.new(
          caller_id: data['caller_id'],
          message: data['message'],
          receiver_kind: data['receiver_kind'].to_sym,
          receiver_name: data['receiver_name'],
          file: data['file'],
          line: data['line'].to_i,
          test: data['test'],
          dynamic: data['dynamic'],
          metadata: data['metadata'] || {}
        )
      end

      def deserialize_class_info(data)
        ClassInfo.new(
          id: data['id'],
          kind: data['kind'].to_sym,
          file: data['file'],
          line: data['line'],
          superclass: data['superclass'],
          superclass_candidates: Array(data['superclass_candidates']),
          includes: Array(data['includes']),
          prepends: Array(data['prepends']),
          extends: Array(data['extends']),
          dynamic: data['dynamic']
        )
      end

      def deserialize_entry_point(data)
        EntryPoint.new(node_id: data['node_id'], reason: data['reason'].to_sym)
      end

      def deserialize_uncertainties(data)
        Hash.new { |hash, key| hash[key] = [] }.tap do |uncertainties|
          (data || {}).each { |node_id, messages| uncertainties[node_id] = Array(messages) }
        end
      end

      def warn_cache(message)
        warn "Necropsy: #{message}" if project.config.verbose?
      end
    end
  end
end
