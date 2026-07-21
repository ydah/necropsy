# frozen_string_literal: true

module Necropsy
  class Reporter
    FORMATS = %i[human json yaml yml sarif github annotations].freeze

    def initialize(report)
      @report = report
    end

    def render(format: :human, min_confidence: :low)
      normalized_format = format.to_sym
      raise Error, "Unknown report format: #{format}" unless FORMATS.include?(normalized_format)

      case normalized_format
      when :json
        report.to_json
      when :sarif
        render_sarif(min_confidence)
      when :github, :annotations
        render_github_annotations(min_confidence)
      when :yaml, :yml
        report.to_yaml
      when :human
        render_human(min_confidence)
      end
    end

    private

    attr_reader :report

    def render_human(min_confidence)
      findings = report.dead_methods(min_confidence: min_confidence)
      lines = [
        'Necropsy report',
        "Root: #{report.root}",
        "Nodes: #{report.summary['nodes']}, Edges: #{report.summary['edges']}, Entry points: #{report.summary['entry_points']}",
        "Findings: #{findings.length}"
      ]

      findings.group_by(&:classification).sort_by do |classification, _|
        classification.to_s
      end.each do |classification, group|
        lines << ''
        lines << "#{classification} (#{group.length})"
        group.sort_by { |finding| [finding.node.file, finding.node.line, finding.node.id] }.each do |finding|
          lines << "  [#{finding.confidence}] #{finding.node.id} #{finding.node.file}:#{finding.node.line}"
        end
      end

      lines.join("\n")
    end

    def render_github_annotations(min_confidence)
      report.dead_methods(min_confidence: min_confidence).map do |finding|
        message = "#{finding.classification} #{finding.node.id} confidence=#{finding.confidence}"
        escaped = message.gsub('%', '%25').gsub("\n", '%0A').gsub("\r", '%0D')
        "::warning file=#{finding.node.file},line=#{finding.node.line},title=Necropsy #{finding.confidence}::#{escaped}"
      end.join("\n")
    end

    def render_sarif(min_confidence)
      findings = report.dead_methods(min_confidence: min_confidence)
      {
        'version' => '2.1.0',
        '$schema' => 'https://json.schemastore.org/sarif-2.1.0.json',
        'runs' => [
          {
            'tool' => {
              'driver' => {
                'name' => 'Necropsy',
                'informationUri' => 'https://github.com/ydah/necropsy',
                'rules' => sarif_rules(findings)
              }
            },
            'results' => findings.map { |finding| sarif_result(finding) }
          }
        ]
      }.to_json
    end

    def sarif_rules(findings)
      findings.map(&:classification).uniq.map do |classification|
        {
          'id' => classification.to_s,
          'name' => classification.to_s,
          'shortDescription' => { 'text' => "Necropsy #{classification}" }
        }
      end
    end

    def sarif_result(finding)
      {
        'ruleId' => finding.classification.to_s,
        'level' => sarif_level(finding),
        'message' => { 'text' => "#{finding.node.id} is #{finding.classification} (#{finding.confidence})" },
        'locations' => [
          {
            'physicalLocation' => {
              'artifactLocation' => { 'uri' => finding.node.file },
              'region' => { 'startLine' => finding.node.line }
            }
          }
        ],
        'partialFingerprints' => { 'necropsy' => finding.fingerprint }
      }
    end

    def sarif_level(finding)
      return 'error' if %i[certain high].include?(finding.confidence)
      return 'warning' if finding.confidence == :medium

      'note'
    end
  end
end
