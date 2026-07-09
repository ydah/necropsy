# frozen_string_literal: true

module Sample
  module Renderable
    def decorated
      render
    end
  end

  class BaseWidget
    def inherited_live
      :base
    end
  end

  class Widget < BaseWidget
    include Renderable

    before_save :persist_callback

    class << self
      def build_live
        new.decorated
      end
    end

    def render
      live_helper
      inherited_live
      map(&:to_s)
    end

    def live_helper
      :ok
    end

    alias alias_live live_helper

    def each
      yield live_helper
    end

    def <=>(_other)
      0
    end

    def persist_callback
      :saved
    end

    def dead_model
      :dead
    end

    def test_only
      :covered_by_test_only
    end
  end
end
