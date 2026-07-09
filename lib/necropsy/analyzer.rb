# frozen_string_literal: true

module Necropsy
  class Analyzer
    def analyze(_graph, _project)
      raise NotImplementedError, "#{self.class} must implement #analyze"
    end

    def profile
      raise NotImplementedError, "#{self.class} must implement #profile"
    end

    private

    def evidence(kind:, details:, analyzer: profile.name, weight: 1.0, metadata: {})
      Evidence.new(analyzer: analyzer, kind: kind, weight: weight, details: details, metadata: metadata)
    end
  end
end
