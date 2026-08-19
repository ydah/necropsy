# frozen_string_literal: true

require_relative 'analysis_services'

module Necropsy
  class CLI
    module Commands
      class Resolver
        COMMANDS = {
          'analyze' => { file: 'analyze', class_name: 'Analyze', dependencies: %i[analysis report_emitter health] },
          'baseline' => { file: 'baseline', class_name: 'Baseline', dependencies: %i[analysis health baseline clock] },
          'check' => { file: 'check', class_name: 'Check', dependencies: %i[analysis report_emitter health baseline configuration] },
          'quarantine' => { file: 'quarantine', class_name: 'Quarantine', dependencies: %i[analysis health clock] },
          'bench' => { file: 'bench', class_name: 'Bench', dependencies: %i[analysis health configuration] },
          'doctor' => { file: 'doctor', class_name: 'Doctor', dependencies: %i[analysis configuration] },
          'feedback' => { file: 'feedback', class_name: 'Feedback', dependencies: %i[workflow] },
          'diff' => { file: 'diff', class_name: 'Diff', dependencies: %i[diff] },
          'plan' => { file: 'removal', class_name: 'Removal', dependencies: %i[removal] },
          'patch' => { file: 'removal', class_name: 'Removal', dependencies: %i[removal] },
          'verify' => { file: 'removal', class_name: 'Removal', dependencies: %i[removal] },
          'why' => { file: 'diagnostics', class_name: 'Diagnostics', dependencies: %i[analysis health diagnostics] },
          'why-not' => { file: 'diagnostics', class_name: 'Diagnostics', dependencies: %i[analysis health diagnostics] },
          'explain' => { file: 'diagnostics', class_name: 'Diagnostics', dependencies: %i[analysis health diagnostics] },
          'semantics' => { file: 'semantics', class_name: 'Semantics', dependencies: [] },
          'record' => { file: 'runtime', class_name: 'Record', dependencies: %i[runtime_evidence] },
          'coverage' => { file: 'runtime', class_name: 'Coverage', dependencies: %i[runtime_evidence] }
        }.freeze

        def initialize(analysis:, report_emitter:, health:, configuration:, clock:, runtime_evidence:)
          @dependencies = {
            analysis: analysis,
            report_emitter: report_emitter,
            health: health,
            configuration: configuration,
            clock: clock,
            runtime_evidence: runtime_evidence
          }
        end

        def resolve(command)
          specification = COMMANDS[command]
          return unless specification

          require_relative specification.fetch(:file)
          command_class = Commands.const_get(specification.fetch(:class_name), false)
          dependencies = specification.fetch(:dependencies).to_h { |name| [name, dependency(name)] }
          dependencies[:command] = command if %w[why why-not explain plan patch verify].include?(command)
          command_class.new(**dependencies)
        end

        private

        def dependency(name)
          return @dependencies.fetch(name) if @dependencies.key?(name)

          case name
          when :baseline then Guardrail::Baseline
          when :workflow then FeedbackWorkflow
          when :diff then Guardrail::Diff
          when :removal then RemovalWorkflow
          when :diagnostics then ::Necropsy::Diagnostics
          else raise KeyError, "Unknown CLI command dependency: #{name}"
          end
        end
      end
    end
  end
end
