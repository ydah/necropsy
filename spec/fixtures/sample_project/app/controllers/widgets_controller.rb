# frozen_string_literal: true

module Sample
  class WidgetsController
    def index
      Widget.build_live
    end

    def audit
      Widget.build_live
    end

    def legacy
      Widget.build_live
    end

    def contextual
      Widget.build_live
    end

    def scoped
      Widget.build_live
    end
  end
end
