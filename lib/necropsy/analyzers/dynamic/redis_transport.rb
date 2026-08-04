# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'timeout'

require_relative 'redis_nonblocking_io'

module Necropsy
  module Analyzers
    module Dynamic
      class RedisCommandError < StandardError; end

      class RedisTransport
        include RedisNonblockingIO

        CRLF = "\r\n"

        def initialize(uri:, limits:, deadline:, redactor:)
          @uri = uri
          @limits = limits
          @deadline = deadline
          @redactor = redactor
          @response_bytes = 0
          @read_buffer = +''
        end

        def connect
          @tcp_socket = connect_tcp
          @socket = uri.scheme == 'rediss' ? connect_tls : tcp_socket
          deadline.check!
          self
        rescue Error
          close
          raise
        rescue SystemCallError, SocketError, IO::TimeoutError, OpenSSL::SSL::SSLError => e
          close
          domain_error("Could not connect securely to Redis at #{target}: #{e.message}")
        end

        def close
          socket&.close
          tcp_socket&.close unless socket.equal?(tcp_socket)
        rescue IOError, SystemCallError
          nil
        ensure
          @socket = nil
          @tcp_socket = nil
        end

        def command(*parts)
          deadline.check!
          write_all(redis_command(parts))
          response = read_response
          deadline.check!
          response
        rescue RedisCommandError
          raise
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
          domain_error("Redis connection failed: #{e.message}")
        end

        private

        attr_reader :uri, :limits, :deadline, :redactor, :socket, :tcp_socket

        def connect_tcp
          expires_at = monotonic_time + limits.connect_timeout
          last_error = nil
          addresses(expires_at).each do |address|
            candidate = Socket.new(address.afamily, address.socktype, address.protocol)
            begin
              finish_tcp_connect(candidate, address, expires_at)
              return candidate
            rescue SystemCallError, SocketError => e
              candidate.close
              last_error = e
            rescue Error
              candidate.close
              raise
            end
          end
          raise(last_error || SocketError.new("No Redis address found for #{uri.host}"))
        end

        def addresses(expires_at)
          timeout = [expires_at - monotonic_time, deadline.remaining].min
          domain_error('Redis address resolution timeout exceeded') unless timeout.positive?

          # Limit asynchronous interruption to pure resolution, before any socket resource exists.
          resolved = Timeout.timeout(timeout) do
            Addrinfo.getaddrinfo(uri.host, uri.port || 6379, nil, :STREAM)
          end
          deadline.check!
          domain_error('Redis address resolution timeout exceeded') unless (expires_at - monotonic_time).positive?
          resolved
        rescue Timeout::Error
          deadline.check!
          domain_error('Redis address resolution timeout exceeded')
        end

        def finish_tcp_connect(candidate, address, expires_at)
          status = candidate.connect_nonblock(address, exception: false)
          return unless wait_status?(status)

          wait_for_io(status, io: candidate, expires_at: expires_at, label: 'Redis connect timeout exceeded')
          error = candidate.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
          raise SystemCallError.new("connect(2) for #{target}", error) unless error.zero?
        rescue Errno::EISCONN
          nil
        end

        def connect_tls
          context = OpenSSL::SSL::SSLContext.new
          store = OpenSSL::X509::Store.new
          store.set_default_paths
          context.cert_store = store
          context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          context.verify_hostname = true if context.respond_to?(:verify_hostname=)

          ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
          ssl_socket.sync_close = true
          ssl_socket.hostname = uri.host
          finish_tls_connect(ssl_socket)
          ssl_socket.post_connection_check(uri.host)
          ssl_socket
        rescue StandardError
          ssl_socket&.close
          raise
        end

        def target
          "#{uri.host}:#{uri.port || 6379}"
        end

        def redis_command(parts)
          encoded = parts.flat_map { |part| ["$#{part.to_s.bytesize}", part.to_s] }
          (["*#{parts.length}"] + encoded).join(CRLF) + CRLF
        end

        def read_response(depth = 0)
          prefix = read_exact(1)
          case prefix
          when '+' then read_line
          when '-' then raise RedisCommandError, redactor.redact(read_line)
          when ':' then read_integer('integer')
          when '$' then read_bulk_string
          when '*' then read_array(depth)
          else domain_error("Malformed Redis response prefix #{prefix.inspect}")
          end
        end

        def read_bulk_string
          length = read_integer('bulk length', nullable: true)
          return nil if length == -1

          domain_error('Invalid negative Redis bulk length') if length.negative?
          domain_error('Redis bulk response exceeds configured limit') if length > limits.max_bulk_bytes

          value = read_exact(length)
          domain_error('Malformed Redis bulk response terminator') unless read_exact(2) == CRLF
          value
        end

        def read_array(depth)
          length = read_integer('array length', nullable: true)
          return nil if length == -1

          domain_error('Invalid negative Redis array length') if length.negative?
          domain_error('Redis array response exceeds configured element limit') if length > limits.max_array_elements

          child_depth = depth + 1
          domain_error('Redis response exceeds configured nesting depth') if child_depth > limits.max_resp_depth
          Array.new(length) { read_response(child_depth) }
        end

        def read_integer(label, nullable: false)
          text = read_line
          domain_error("Malformed Redis #{label}") unless text.match?(/\A-?\d+\z/)

          value = Integer(text, 10)
          domain_error("Invalid negative Redis #{label}") if value.negative? && (!nullable || value < -1)
          value
        end

        def read_line
          loop do
            if (terminator = @read_buffer.index(CRLF))
              return @read_buffer.slice!(0, terminator + CRLF.bytesize).delete_suffix(CRLF)
            end

            fill_buffer
          end
        end

        def read_exact(length)
          fill_buffer while @read_buffer.bytesize < length
          @read_buffer.slice!(0, length)
        end

        def fill_buffer
          deadline.check!
          remaining = limits.max_response_bytes - @response_bytes
          domain_error('Redis response exceeds configured byte limit') unless remaining.positive?

          chunk = read_nonblock([4096, remaining].min)
          @response_bytes += chunk.bytesize
          @read_buffer << chunk
        end

        def domain_error(message)
          raise Error, redactor.redact(message), cause: nil
        end
      end
    end
  end
end
