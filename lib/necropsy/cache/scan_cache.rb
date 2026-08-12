# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'

module Necropsy
  module Cache
    class ScanCache
      VERSION = 13

      def initialize(project:)
        @project = project
      end

      def fetch(files)
        return yield unless project.config.cache_enabled?

        metadata = safe_cache_metadata(files)
        return yield unless metadata

        cached = read(metadata)
        return cached if cached

        result = yield
        write(metadata, result)
        result
      end

      private

      attr_reader :project

      def safe_cache_metadata(files)
        cache_metadata(files)
      rescue SystemCallError, JSON::ParserError => e
        warn_cache("Cache unavailable: #{e.message}")
        nil
      end

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
        payload = JSON.generate(
          'version' => VERSION,
          'metadata' => metadata,
          'scan_result' => serialize_scan_result(result)
        )
        temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.write(temporary, payload)
        File.rename(temporary, path)
      rescue StandardError => e
        warn_cache("Could not write cache: #{e.message}")
      ensure
        FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
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
            'mtime' => "#{stat.mtime.to_i}.#{stat.mtime.nsec}",
            'content_sha256' => Digest::SHA256.file(file).hexdigest
          }
        end
      end

      def cache_metadata(files)
        {
          'files' => file_metadata(files),
          'inventory' => project.scan_inventory_key,
          'configuration' => project.config.scan_cache_key,
          'environment' => {
            'necropsy_version' => Necropsy::VERSION,
            'ruby_engine' => RUBY_ENGINE,
            'ruby_version' => RUBY_VERSION,
            'prism_version' => Prism::VERSION,
            'definition_identity_version' => DefinitionIdentity::VERSION,
            'call_site_identity_version' => CallSiteIdentity::VERSION
          }
        }
      end

      def serialize_scan_result(result)
        {
          'nodes' => result.nodes.map(&:to_h),
          'call_sites' => result.call_sites.map(&:to_h),
          'instantiated_classes' => result.instantiated_classes.to_a.sort,
          'uncertainties' => result.uncertainties.transform_values { |messages| Array(messages).map(&:to_s) },
          'class_infos' => result.class_infos.map(&:to_h),
          'entrypoint_hints' => result.entrypoint_hints.map(&:to_h),
          'file_statuses' => result.file_statuses.transform_values(&:to_s),
          'source_errors' => result.source_errors.map(&:to_h),
          'source_domains' => result.source_domains.transform_values(&:to_s),
          'scope_diagnostics' => result.scope_diagnostics,
          'method_signatures' => result.method_signatures,
          'semantic_blockers' => result.semantic_blockers.map(&:to_h)
        }
      end

      def deserialize_scan_result(data)
        ScanResult.new(
          nodes: Array(data['nodes']).map { |node| deserialize_node(node) },
          call_sites: Array(data['call_sites']).map { |site| deserialize_call_site(site) },
          instantiated_classes: Set.new(Array(data['instantiated_classes'])),
          uncertainties: deserialize_uncertainties(data['uncertainties']),
          class_infos: Array(data['class_infos']).map { |info| deserialize_class_info(info) },
          entrypoint_hints: Array(data['entrypoint_hints']).map { |entry| deserialize_entry_point(entry) },
          file_statuses: (data['file_statuses'] || {}).transform_values(&:to_sym),
          source_errors: Array(data['source_errors']).map { |error| deserialize_source_error(error) },
          source_domains: (data['source_domains'] || {}).transform_values(&:to_sym),
          scope_diagnostics: data['scope_diagnostics'] || {},
          method_signatures: data['method_signatures'] || {},
          semantic_blockers: Array(data['semantic_blockers']).map { |blocker| deserialize_blocker(blocker) }
        )
      end

      def deserialize_blocker(data)
        Blocker.new(
          kind: data.fetch('kind').to_sym,
          scope_kind: data.fetch('scope_kind').to_sym,
          scope_value: data['scope_value'],
          source: data['source'],
          reason: data.fetch('reason'),
          suggested_action: data.fetch('suggested_action', 'review').to_sym,
          metadata: data['metadata'] || {}
        )
      end

      def deserialize_source_error(data)
        SourceError.new(
          file: data['file'],
          line: data['line']&.to_i || 1,
          message: data['message'],
          type: data['type'].to_sym
        )
      end

      def deserialize_node(data)
        id = data.fetch('id')
        Node.new(
          id: id,
          symbol_id: data['symbol_id'] || id,
          definition_id: data['definition_id'] || id,
          body_digest: data['body_digest'],
          ordinal: data['ordinal'].to_i,
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
          call_site_id: data.fetch('call_site_id'),
          caller_id: data['caller_definition_id'] || data.fetch('caller_id'),
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
          singleton_includes: Array(data['singleton_includes']),
          singleton_prepends: Array(data['singleton_prepends']),
          dynamic: data['dynamic']
        )
      end

      def deserialize_entry_point(data)
        Root.new(
          definition_id: data['definition_id'] || data['node_id'],
          domain: data['domain'],
          reason: data['reason'].to_sym,
          evidence: data['evidence']
        )
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
