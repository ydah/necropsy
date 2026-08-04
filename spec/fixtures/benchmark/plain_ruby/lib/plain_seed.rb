# frozen_string_literal: true

module PlainSeed
  class Formatter
    def format(value)
      normalize(value)
    end

    def normalize(value)
      value.to_s.strip
    end

    def unused
      :dead
    end

    def public_extension
      :extension_point
    end
  end

  class Runner
    def self.call
      Formatter.new.format(' seed ')
    end

    def legacy
      :dead
    end
  end
end
