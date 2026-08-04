# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'rbconfig'

module Necropsy
  module Bench
    class ReleaseAudit
      class RunProvenance
        SCHEMA_VERSION = 1

        def initialize(root:, manifest_path:, config_path:, output_dir:, command:)
          @root = File.expand_path(root)
          @manifest_path = File.expand_path(manifest_path)
          @config_path = File.expand_path(config_path)
          @output_dir = File.expand_path(output_dir)
          @command = command
        end

        def capture_source!
          ensure_clean!
          {
            'schema_version' => SCHEMA_VERSION,
            'git_ref' => git_head,
            'clean' => true,
            'manifest_sha256' => digest(manifest_path),
            'audit_config_sha256' => digest(config_path)
          }
        end

        def complete(source, summary)
          source.merge(
            'environment' => environment(summary),
            'artifacts' => artifact_digests
          )
        end

        def write(path, payload)
          File.write(path, "#{JSON.pretty_generate(payload)}\n")
        end

        def load_and_validate!(path)
          payload = JSON.parse(File.read(path))
          expected = capture_source!
          expected.each do |key, value|
            raise Error, "Benchmark provenance mismatch for #{key}" unless payload[key] == value
          end
          validate_environment!(payload.fetch('environment'))
          raise Error, 'Benchmark provenance mismatch for artifacts' unless payload['artifacts'] == artifact_digests

          payload
        rescue Errno::ENOENT, JSON::ParserError => e
          raise Error, "Could not load benchmark provenance: #{e.message}"
        end

        private

        attr_reader :root, :manifest_path, :config_path, :output_dir, :command

        def ensure_clean!
          output, status = Open3.capture2e('git', 'status', '--porcelain', chdir: root)
          raise Error, "Could not inspect audit worktree: #{output.strip}" unless status.success?
          raise Error, 'Release audit requires a clean tracked worktree' unless output.strip.empty?
        end

        def git_head
          output, status = Open3.capture2e('git', 'rev-parse', 'HEAD', chdir: root)
          raise Error, "Could not resolve audit HEAD: #{output.strip}" unless status.success?

          output.strip
        end

        def digest(path)
          Digest::SHA256.file(path).hexdigest
        end

        def environment(summary)
          performances = summary.fetch('corpora').filter_map { |corpus| corpus['performance'] }
          rss_kinds = performances.filter_map { |item| item['rss_kind'] }.uniq
          rss_scopes = performances.filter_map { |item| item['rss_scope'] }.uniq
          {
            'ruby' => RUBY_DESCRIPTION,
            'os' => operating_system,
            'command' => command,
            'rss_kind' => rss_kinds.one? ? rss_kinds.first : 'unavailable_or_mixed',
            'rss_scope' => rss_scopes.one? ? rss_scopes.first : 'unavailable_or_mixed'
          }
        end

        def validate_environment!(recorded)
          actual = {
            'ruby' => RUBY_DESCRIPTION,
            'os' => operating_system,
            'command' => command
          }
          mismatch = actual.find { |key, value| recorded[key] != value }
          raise Error, "Benchmark provenance mismatch for environment #{mismatch.first}" if mismatch
        end

        def artifact_digests
          paths = [File.join(output_dir, 'summary.json'), *Dir.glob(File.join(output_dir, 'reports', '*.json'))]
          raise Error, 'Benchmark provenance requires a summary and normalized reports' unless paths.length > 1

          paths.sort.to_h do |path|
            relative = path.delete_prefix("#{output_dir}/")
            [relative, digest(path)]
          end
        rescue Errno::ENOENT => e
          raise Error, "Could not hash benchmark artifacts: #{e.message}"
        end

        def operating_system
          version = capture('sw_vers', '-productVersion')
          build = capture('sw_vers', '-buildVersion')
          kernel = capture('uname', '-r')
          machine = capture('uname', '-m')
          return "macOS #{version} (#{build}), Darwin #{kernel} #{machine}" if version && build && kernel && machine

          [RbConfig::CONFIG['host_os'], RbConfig::CONFIG['host_cpu']].compact.join(' ')
        end

        def capture(*command_parts)
          output, status = Open3.capture2e(*command_parts)
          status.success? ? output.strip : nil
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
