# frozen_string_literal: true

require_relative '../../doctor'

module Necropsy
  class CLI
    module Commands
      class Doctor
        def initialize(analysis:, configuration:)
          @analysis = analysis
          @configuration = configuration
        end

        def call(options:, arguments:)
          raise Error, "Unexpected doctor arguments: #{arguments.join(' ')}" unless arguments.empty?

          report = @analysis.call(options: options)
          config = @configuration.load(root: File.expand_path(options[:root]), path: options[:config])
          doctor = ::Necropsy::Doctor.new(report: report, config: config)
          puts doctor.render(format: options[:format])
          result = doctor.call
          return 1 if result.fetch('status') == 'error'

          result.fetch('checks').any? { |check| check.fetch('status') == 'issue' } ? 1 : 0
        end
      end
    end
  end
end
