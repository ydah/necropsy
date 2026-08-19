# frozen_string_literal: true

require_relative 'analysis'

module Necropsy
  class CLI
    module Options
      class Doctor < Analysis; end
    end
  end
end
