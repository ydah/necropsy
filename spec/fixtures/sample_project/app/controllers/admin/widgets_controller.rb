# frozen_string_literal: true

module Sample
  module Admin
    class WidgetsController
      def index
        Widget.build_live
      end

      def preview
        Widget.new.render
      end

      def drawn
        Widget.new.render
      end
    end
  end
end
