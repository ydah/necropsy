# frozen_string_literal: true

require 'yaml'
require 'time'

module Necropsy
  module Guardrail
    class Baseline
      attr_reader :path, :fingerprints

      def self.load(path)
        return new(path: path, fingerprints: []) unless File.exist?(path)

        payload = YAML.load_file(path) || {}
        new(path: path, fingerprints: Array(payload['findings']).map { |finding| finding['fingerprint'] })
      end

      def self.write(report, path:)
        findings = report.findings.map do |finding|
          {
            'fingerprint' => finding.fingerprint,
            'classification' => finding.classification.to_s,
            'confidence' => finding.confidence.to_s,
            'node_id' => finding.node.id,
            'file' => finding.node.file,
            'line' => finding.node.line
          }
        end
        payload = {
          'version' => 1,
          'generated_at' => Time.now.utc.iso8601,
          'findings' => findings
        }
        File.write(path, payload.to_yaml)
      end

      def initialize(path:, fingerprints:)
        @path = path
        @fingerprints = fingerprints
      end

      def include?(finding)
        fingerprints.include?(finding.fingerprint)
      end
    end
  end
end
