# frozen_string_literal: true

require 'date'

module Necropsy
  class Clock
    SOURCE_DATE_EPOCH = 'SOURCE_DATE_EPOCH'

    attr_reader :time

    def initialize(as_of: nil, environment: ENV, now: nil)
      @time = resolve_time(as_of, environment, now).utc.freeze
    rescue ArgumentError, TypeError, RangeError
      raise Error, 'as-of time and SOURCE_DATE_EPOCH must identify a valid date'
    end

    def date
      time.to_date
    end

    private

    def resolve_time(as_of, environment, now)
      return time_for_as_of(as_of) unless as_of.nil?

      epoch = environment[SOURCE_DATE_EPOCH]
      return Time.at(Integer(epoch), in: '+00:00') unless epoch.nil? || epoch.empty?

      value = now.respond_to?(:call) ? now.call : now
      value || Time.now.utc
    end

    def time_for_as_of(value)
      return value if value.is_a?(Time)

      date = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
      Time.utc(date.year, date.month, date.day)
    end
  end
end
