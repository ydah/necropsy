# frozen_string_literal: true

class DynamicSeed
  def run
    helper
  end

  def helper
    :live
  end

  def observed_only
    :runtime
  end

  def dead
    :dead
  end

  def public_hook
    :external_hook
  end
end

DynamicSeed.new.run
