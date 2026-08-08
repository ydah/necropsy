# frozen_string_literal: true

require 'json'

module Necropsy
  # Small, dependency-free phase profiler used by benchmark and local analysis.
  # It is opt-in so ordinary reports remain byte-for-byte compatible.
  class PerformanceProfiler
    SCHEMA_VERSION = 1

    def initialize(clock: Process.method(:clock_gettime), rss_reader: nil, allocation_reader: nil)
      @clock = clock
      @rss_reader = rss_reader || method(:process_rss_kb)
      @allocation_reader = allocation_reader || method(:allocated_objects)
      @phases = []
      @peak_rss_kb = nil
    end

    attr_reader :phases

    def measure(name)
      started = snapshot
      value = yield
      finished = snapshot
      @phases << phase_payload(name, started, finished)
      value
    end

    def report(counts: {}, report_index_size_bytes: nil)
      total_time = @phases.sum { |phase| phase.fetch('wall_time_seconds') }
      total_allocations = @phases.sum { |phase| phase.fetch('allocated_objects') }
      {
        'schema_version' => SCHEMA_VERSION,
        'phases' => @phases.sort_by { |phase| phase.fetch('name') },
        'totals' => {
          'wall_time_seconds' => total_time.round(6),
          'allocated_objects' => total_allocations
        },
        'memory' => {
          'peak_rss_kb' => @peak_rss_kb,
          'rss_status' => @peak_rss_kb ? 'available' : 'unavailable'
        },
        'counts' => normalize_counts(counts),
        'report_index_size_bytes' => report_index_size_bytes
      }.compact
    end

    private

    attr_reader :clock, :rss_reader, :allocation_reader

    def snapshot
      {
        'time' => clock.call(Process::CLOCK_MONOTONIC),
        'rss_kb' => rss_reader.call,
        'allocations' => allocation_reader.call
      }
    rescue StandardError
      {
        'time' => clock.call(Process::CLOCK_MONOTONIC),
        'rss_kb' => nil,
        'allocations' => nil
      }
    end

    def phase_payload(name, started, finished)
      elapsed = [finished.fetch('time') - started.fetch('time'), 0].max
      allocated = if started['allocations'] && finished['allocations']
                    [finished['allocations'] - started['allocations'], 0].max
                  else
                    0
                  end
      rss = [started['rss_kb'], finished['rss_kb']].compact.max
      @peak_rss_kb = [@peak_rss_kb, rss].compact.max
      {
        'name' => name.to_s,
        'wall_time_seconds' => elapsed.round(6),
        'allocated_objects' => allocated,
        'rss_kb' => rss
      }.compact
    end

    def normalize_counts(counts)
      Hash(counts).to_h { |key, value| [key.to_s, Integer(value)] }.sort.to_h
    rescue ArgumentError, TypeError
      {}
    end

    def allocated_objects
      GC.stat.fetch(:total_allocated_objects, 0)
    rescue StandardError
      0
    end

    def process_rss_kb
      status_path = '/proc/self/status'
      if File.file?(status_path)
        match = File.read(status_path).match(/^VmRSS:\s+(\d+)\s+kB$/)
        return match[1].to_i if match
      end

      output = IO.popen(['ps', '-o', 'rss=', '-p', Process.pid.to_s], &:read)
      Integer(output.strip, exception: false)
    rescue StandardError
      nil
    end
  end
end
