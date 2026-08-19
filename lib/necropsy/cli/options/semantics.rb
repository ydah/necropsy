# frozen_string_literal: true

require_relative 'base'

module Necropsy
  class CLI
    module Options
      class Semantics < Base
        private

        def define_options
          add_format_option
        end
      end
    end
  end
end
