# frozen_string_literal: true

require_relative 'analysis'

module Necropsy
  class CLI
    module Options
      class Quarantine < Analysis
        private

        def define_options
          super
          options[:write] = false
          parser.on('--write', 'Write quarantine annotations') { options[:write] = true }
        end
      end
    end
  end
end
