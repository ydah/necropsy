# frozen_string_literal: true

require_relative 'reporters/github_annotations'
require_relative 'reporters/human'
require_relative 'reporters/ndjson'
require_relative 'reporters/sarif'
require_relative 'reporters/support'

module Necropsy
  class Reporter
    FORMATS = %i[human json ndjson yaml yml sarif github annotations].freeze
    DEFAULT_MIN_CONFIDENCE = :medium

    def initialize(report)
      @report = report
    end

    def self.render_baseline_review(review_report)
      Reporters::Human.render_baseline_review(review_report)
    end

    def self.render_analysis_health(analysis_health)
      Reporters::Human.render_analysis_health(analysis_health)
    end

    def render(format: :human, min_confidence: DEFAULT_MIN_CONFIDENCE, include_graph: false)
      normalized_format = format.to_sym
      raise Error, "Unknown report format: #{format}" unless FORMATS.include?(normalized_format)

      case normalized_format
      when :json
        report.to_json(include_graph: include_graph)
      when :ndjson
        each_ndjson.to_a.join("\n")
      when :sarif
        Reporters::Sarif.new(report).render(min_confidence)
      when :github, :annotations
        Reporters::GithubAnnotations.new(report).render(min_confidence)
      when :yaml, :yml
        report.to_yaml(include_graph: include_graph)
      when :human
        Reporters::Human.new(report).render(min_confidence)
      end
    end

    def each_ndjson(&block)
      return Reporters::Ndjson.new(report).each unless block

      Reporters::Ndjson.new(report).each(&block)
    end

    private

    attr_reader :report
  end
end
