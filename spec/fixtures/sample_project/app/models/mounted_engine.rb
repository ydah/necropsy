# frozen_string_literal: true

module Sample
  class MountedEngine
    def self.call(_env)
      :ok
    end
  end
end
