# frozen_string_literal: true

require 'io/wait'

module Necropsy
  module Analyzers
    module Dynamic
      module RedisNonblockingIO
        private

        def finish_tls_connect(ssl_socket)
          expires_at = monotonic_time + limits.connect_timeout
          loop do
            status = ssl_socket.connect_nonblock(exception: false)
            return unless wait_status?(status)

            wait_for_io(status, io: ssl_socket.to_io, expires_at: expires_at,
                                label: 'Redis TLS handshake timeout exceeded')
          rescue IO::WaitReadable
            wait_for_io(:wait_readable, io: ssl_socket.to_io, expires_at: expires_at,
                                        label: 'Redis TLS handshake timeout exceeded')
          rescue IO::WaitWritable
            wait_for_io(:wait_writable, io: ssl_socket.to_io, expires_at: expires_at,
                                        label: 'Redis TLS handshake timeout exceeded')
          end
        end

        def write_all(value)
          offset = 0
          expires_at = monotonic_time + limits.read_timeout
          while offset < value.bytesize
            check_io_deadline!(expires_at, 'Redis write timeout exceeded')
            begin
              written = socket.write_nonblock(value.byteslice(offset, value.bytesize - offset), exception: false)
              if wait_status?(written)
                wait_for_io(written, io: socket.to_io, expires_at: expires_at, label: 'Redis write timeout exceeded')
              elsif written&.positive?
                offset += written
              else
                domain_error('Redis closed the connection while writing a request')
              end
            rescue IO::WaitReadable
              wait_for_io(:wait_readable, io: socket.to_io, expires_at: expires_at,
                                          label: 'Redis write timeout exceeded')
            rescue IO::WaitWritable
              wait_for_io(:wait_writable, io: socket.to_io, expires_at: expires_at,
                                          label: 'Redis write timeout exceeded')
            end
          end
          check_io_deadline!(expires_at, 'Redis write timeout exceeded')
        end

        def read_nonblock(length)
          expires_at = monotonic_time + limits.read_timeout
          loop do
            value = socket.read_nonblock(length, exception: false)
            return value if value.is_a?(String) && !value.empty?

            domain_error('Redis closed the connection while reading a response') if value.nil? || value == ''
            wait_for_io(value, io: socket.to_io, expires_at: expires_at, label: 'Redis read timeout exceeded')
          rescue IO::WaitReadable
            wait_for_io(:wait_readable, io: socket.to_io, expires_at: expires_at, label: 'Redis read timeout exceeded')
          rescue IO::WaitWritable
            wait_for_io(:wait_writable, io: socket.to_io, expires_at: expires_at, label: 'Redis read timeout exceeded')
          end
        end

        def wait_status?(value)
          %i[wait_readable wait_writable].include?(value)
        end

        def check_io_deadline!(expires_at, label)
          deadline.check!
          domain_error(label) unless (expires_at - monotonic_time).positive?
        end

        def wait_for_io(status, io:, expires_at:, label:)
          timeout = [expires_at - monotonic_time, deadline.remaining].min
          domain_error(label) unless timeout.positive?

          ready = status == :wait_readable ? io.wait_readable(timeout) : io.wait_writable(timeout)
          return if ready

          deadline.check!
          domain_error(label)
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
