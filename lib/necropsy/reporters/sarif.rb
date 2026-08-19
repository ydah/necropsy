# frozen_string_literal: true

require 'json'
require_relative 'support'

module Necropsy
  module Reporters
    class Sarif
      include Support

      def initialize(report)
        @report = report
      end

      def render(min_confidence)
        findings = report.dead_methods(min_confidence: min_confidence)
        source_entries = source_diagnostic_entries
        {
          'version' => '2.1.0',
          '$schema' => 'https://json.schemastore.org/sarif-2.1.0.json',
          'runs' => [
            {
              'tool' => {
                'driver' => {
                  'name' => 'Necropsy',
                  'informationUri' => 'https://github.com/ydah/necropsy',
                  'rules' => sarif_rules(findings, source_entries)
                }
              },
              'results' => findings.map { |finding| sarif_result(finding) } +
                source_entries.map { |entry| sarif_source_result(entry) },
              'properties' => {
                'necropsyFingerprintCompatibility' => Report::FINGERPRINT_COMPATIBILITY,
                'analysisHealth' => report.analysis_health.to_h
              }
            }
          ]
        }.to_json
      end

      private

      def sarif_rules(findings, source_entries)
        rules = findings.map(&:classification).uniq.map do |classification|
          {
            'id' => classification.to_s,
            'name' => classification.to_s,
            'shortDescription' => { 'text' => "Necropsy #{classification}" }
          }
        end
        return rules if source_entries.empty?

        rules << {
          'id' => 'parse_incomplete',
          'name' => 'parse_incomplete',
          'shortDescription' => { 'text' => 'Necropsy incomplete source' }
        }
      end

      def sarif_result(finding)
        result = {
          'ruleId' => finding.classification.to_s,
          'level' => sarif_level(finding),
          'message' => { 'text' => "#{finding.node.id} is #{finding.classification} (#{finding.confidence})" },
          'properties' => {
            'symbolId' => finding.node.symbol_id,
            'definitionId' => finding.node.definition_id,
            'logicalFingerprint' => finding.logical_fingerprint,
            'physicalFingerprint' => finding.physical_fingerprint
          },
          'locations' => [
            {
              'physicalLocation' => {
                'artifactLocation' => { 'uri' => finding.node.file },
                'region' => { 'startLine' => finding.node.line }
              }
            }
          ],
          'partialFingerprints' => {
            'necropsy' => finding.logical_fingerprint,
            'necropsyPhysicalDefinition' => finding.physical_fingerprint
          }
        }
        related_locations = sarif_related_locations(finding)
        result['relatedLocations'] = related_locations unless related_locations.empty?
        code_flows = sarif_code_flows(finding)
        result['codeFlows'] = code_flows unless code_flows.empty?
        result
      end

      def sarif_related_locations(finding)
        finding.blockers.filter_map do |blocker|
          metadata = blocker.metadata
          file = metadata['file'] || metadata[:file]
          line = positive_line(metadata['line'] || metadata[:line])
          next if file.to_s.empty? || line.nil?

          {
            'physicalLocation' => sarif_physical_location(file, line),
            'message' => { 'text' => "#{blocker.kind}: #{blocker.reason}" },
            'properties' => {
              'blockerKind' => blocker.kind.to_s,
              'blockerSource' => blocker.source.respond_to?(:to_h) ? blocker.source.to_h : blocker.source.to_s
            }
          }
        end.uniq do |location|
          [
            location.dig('physicalLocation', 'artifactLocation', 'uri'),
            location.dig('physicalLocation', 'region', 'startLine'),
            location.dig('properties', 'blockerKind')
          ]
        end
      end

      def sarif_code_flows(finding)
        witness = sarif_witness(finding.node.graph_id)
        return [] unless witness

        domain, path = witness
        locations = path.each_with_index.filter_map do |definition_id, index|
          node = report.graph.nodes[definition_id]
          next unless node

          {
            'location' => {
              'physicalLocation' => sarif_physical_location(node.file, node.line),
              'message' => { 'text' => node.symbol_id }
            },
            'executionOrder' => index + 1
          }
        end
        return [] if locations.empty?

        [{
          'message' => { 'text' => "#{domain} reachability witness" },
          'threadFlows' => [{ 'locations' => locations }],
          'properties' => { 'domain' => domain.to_s }
        }]
      end

      def sarif_witness(definition_id)
        return unless report.reachability

        %i[runtime external test].each do |domain|
          path = report.reachability.witness(definition_id, kind: domain)
          return [domain, path] if path
        end
        nil
      end

      def sarif_physical_location(file, line)
        {
          'artifactLocation' => { 'uri' => file.to_s },
          'region' => { 'startLine' => line }
        }
      end

      def sarif_level(finding)
        return 'error' if %i[certain high].include?(finding.confidence)
        return 'warning' if finding.confidence == :medium

        'note'
      end

      def sarif_source_result(entry)
        {
          'ruleId' => 'parse_incomplete',
          'level' => 'warning',
          'message' => {
            'text' => "Incomplete source (#{entry['status']}, #{entry['type']}): #{entry['message']}"
          },
          'locations' => [
            {
              'physicalLocation' => {
                'artifactLocation' => { 'uri' => entry['file'] },
                'region' => { 'startLine' => entry['line'] }
              }
            }
          ]
        }
      end
    end
  end
end
