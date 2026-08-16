# frozen_string_literal: true

require 'json'

module Necropsy
  class Doctor
    def initialize(report:, config:)
      @report = report
      @config = config
    end

    def call
      checks = [threshold_check, health_check, scope_check, load_root_check]
      issues = checks.reject { |check| check.fetch('status') == 'ok' }
      {
        'schema_version' => 1,
        'status' => issues.any? { |check| check.fetch('severity') == 'error' } ? 'error' : 'ok',
        'checks' => checks,
        'summary' => @report.summary
      }
    end

    def render(format: :human)
      payload = call
      return JSON.pretty_generate(payload) unless format.to_sym == :human

      lines = ["Necropsy doctor: #{payload.fetch('status')}"]
      payload.fetch('checks').each do |check|
        lines << "  [#{check.fetch('severity')}] #{check.fetch('name')}: #{check.fetch('message')}"
      end
      lines.join("\n")
    end

    private

    def threshold_check
      threshold = @config.fail_on
      if @config.fail_on_actionability?
        if threshold == :new_verified_candidate
          return check(
            'ci_threshold', 'warning',
            'new_verified_candidate is accepted, but no producer currently emits verified candidates',
            configured: threshold.to_s
          )
        end

        return check(
          'ci_threshold', 'ok', 'CI gates on actionability instead of priority confidence',
          configured: threshold.to_s
        )
      end

      check(
        'ci_threshold', 'warning',
        'CI gates on priority confidence; use new_review_candidate for deletion-safety gating',
        configured: threshold.to_s
      )
    rescue Error => e
      check('ci_threshold', 'error', e.message)
    end

    def health_check
      health = @report.analysis_health
      severity = if health.status == :invalid
                   'error'
                 elsif health.complete?
                   'ok'
                 else
                   'warning'
                 end
      message = if health.complete?
                  'analysis health is complete'
                else
                  "analysis health is #{health.status} (#{health.reasons.length} reason(s))"
                end
      check('analysis_health', severity, message, health_status: health.status.to_s, reasons: health.reasons)
    end

    def scope_check
      diagnostics = @report.diagnostics['analysis_scope']
      return check('scope', 'ok', 'analysis and reference scopes are aligned') unless diagnostics

      check('scope', 'warning', 'scope diagnostics require review', details: diagnostics)
    end

    def load_root_check
      units = @report.diagnostics['unrooted_load_units']
      return check('load_roots', 'ok', 'all discovered load units are rooted') unless units

      check('load_roots', 'warning', 'unrooted load units may hide entry points', details: units)
    end

    def check(name, severity, message, **details)
      {
        'name' => name,
        'status' => severity == 'ok' ? 'ok' : 'issue',
        'severity' => severity,
        'message' => message
      }.merge(details)
    end
  end
end
