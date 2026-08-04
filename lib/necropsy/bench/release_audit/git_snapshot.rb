# frozen_string_literal: true

require 'json'
require 'open3'

module Necropsy
  module Bench
    class ReleaseAudit
      class GitSnapshot
        def initialize(root:, git_ref:, reports_path:)
          @root = root
          @git_ref = git_ref
          @reports_path = reports_path
        end

        def reports(corpora)
          corpora.to_h { |corpus| [corpus, report(corpus)] }
        end

        private

        attr_reader :root, :git_ref, :reports_path

        def report(corpus)
          object = "#{git_ref}:#{File.join(reports_path, "#{corpus}.json")}"
          output, status = Open3.capture2e('git', 'show', object, chdir: root)
          raise Error, "Could not read audit baseline #{object}: #{output.strip}" unless status.success?

          JSON.parse(output)
        rescue JSON::ParserError => e
          raise Error, "Could not parse audit baseline #{object}: #{e.message}"
        end
      end
    end
  end
end
