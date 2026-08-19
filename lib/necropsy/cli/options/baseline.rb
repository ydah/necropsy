# frozen_string_literal: true

require_relative 'analysis'

module Necropsy
  class CLI
    module Options
      class Baseline < Analysis
        private

        def define_options
          super
          options[:baseline] = nil
          parser.on('--baseline PATH', 'Baseline path') { |value| options[:baseline] = value }
        end
      end
    end
  end
end
