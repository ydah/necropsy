# frozen_string_literal: true

require 'fileutils'
require 'json'

module Necropsy
  module Bench
    class ReleaseAudit
      class ArtifactWriter
        def initialize(audit:, output_dir:)
          @audit = audit
          @output_dir = output_dir
        end

        def call
          FileUtils.mkdir_p(output_dir)
          File.write(json_path, "#{JSON.pretty_generate(audit)}\n")
          File.write(markdown_path, markdown)
          { json: json_path, markdown: markdown_path }
        end

        private

        attr_reader :audit, :output_dir

        def json_path = File.join(output_dir, 'audit.json')
        def markdown_path = File.join(output_dir, 'audit.md')

        def markdown
          lines = [
            "# #{audit.fetch('release')} safety release audit",
            '',
            "Status: **#{audit.fetch('status').upcase}**",
            '',
            "Baseline: `#{audit.dig('baseline', 'git_ref')}` — #{audit.dig('baseline', 'reason')}",
            '',
            '## Candidate changes',
            '',
            '| corpus | baseline | current | added | removed | state changed | newly high |',
            '|---|---:|---:|---:|---:|---:|---:|'
          ]
          append_candidate_rows(lines)
          append_review(lines)
          append_performance(lines)
          append_adversarial(lines)
          append_claim_gate(lines)
          append_gates(lines)
          "#{lines.join("\n")}\n"
        end

        def append_review(lines)
          lines.push('', '## Difference review', '',
                     '| corpus | strategy | changes | required | completed | zero difference |',
                     '|---|---|---:|---:|---:|:---:|')
          audit.dig('review', 'coverage').sort.each do |corpus, coverage|
            lines << "| #{corpus} | #{coverage['strategy']} | #{coverage['changes']} | #{coverage['required']} | " \
                     "#{coverage['completed']} | #{coverage['zero_difference'] ? 'yes' : 'no'} |"
          end
        end

        def append_candidate_rows(lines)
          new_high = audit.fetch('new_high_candidates').group_by { |candidate| candidate.fetch('corpus') }
          audit.fetch('corpora').sort.each do |corpus, comparison|
            lines << "| #{corpus} | #{comparison.dig('baseline_metrics', 'findings')} | " \
                     "#{comparison.dig('current_metrics', 'findings')} | #{comparison['added'].length} | " \
                     "#{comparison['removed'].length} | #{comparison['state_changed'].length} | " \
                     "#{new_high.fetch(corpus, []).length} |"
          end
        end

        def append_performance(lines)
          lines.push('', '## Performance', '',
                     '| corpus | wall baseline/current/limit (s) | RSS baseline/current/limit (KiB) | pass |',
                     '|---|---:|---:|:---:|')
          audit.fetch('performance').sort.each do |corpus, result|
            lines << "| #{corpus} | #{result['baseline_wall_time_seconds']} / " \
                     "#{result['current_wall_time_seconds']} / #{result['wall_time_limit_seconds']} | " \
                     "#{result['baseline_rss_kb']} / #{result['current_rss_kb']} / #{result['rss_limit_kb']} | " \
                     "#{result['passed'] ? 'yes' : 'no'} |"
          end
        end

        def append_adversarial(lines)
          lines.push('', '## Adversarial suites', '', '| suite | result | summary |', '|---|:---:|---|')
          audit.fetch('adversarial_suites').each do |suite|
            lines << "| #{suite['name']} | #{suite['passed'] ? 'pass' : 'fail'} | #{suite['summary']} |"
          end
        end

        def append_claim_gate(lines)
          claim = audit.fetch('claim_gate')
          return unless claim['enforced']

          lines.push('', '## Public claim gate', '',
                     "Result: **#{claim['passed'] ? 'PASS' : 'FAIL'}**",
                     "Unexplained high candidates: #{claim.fetch('unexplained_high_candidates').length}",
                     "Reviewed high candidates: #{claim.fetch('reviewed_high_candidates')}")
        end

        def append_gates(lines)
          lines.push('', '## Release gates', '', '| gate | result | failures |', '|---|:---:|---:|')
          audit.fetch('gates').sort.each do |name, gate|
            lines << "| #{name} | #{gate['passed'] ? 'pass' : 'fail'} | #{gate['failures']} |"
          end
          lines << ''
          lines << "Reviewed RuboCop/Rails changes: #{audit.dig('review', 'completed').length}; " \
                   "missing: #{audit.dig('review', 'missing').length}."
        end
      end
    end
  end
end
