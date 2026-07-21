# frozen_string_literal: true

require 'yaml'
require 'time'
require 'set'

module Necropsy
  module Guardrail
    class Baseline
      attr_reader :path, :fingerprints

      def self.load(path)
        return new(path: path, findings: []) unless File.exist?(path)

        payload = YAML.load_file(path) || {}
        new(path: path, findings: Array(payload['findings']))
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

      def initialize(path:, findings:)
        @path = path
        @findings = findings
        @fingerprints = findings.filter_map { |finding| finding['fingerprint'] }.to_set
      end

      def include?(finding)
        fingerprints.include?(finding.fingerprint)
      end

      def count_at_least(confidence)
        threshold = CONFIDENCE_LEVELS.fetch(confidence)
        @findings.count do |finding|
          level = finding['confidence']&.to_sym
          level && CONFIDENCE_LEVELS.fetch(level, -1) >= threshold
        end
      end
    end
  end
end
