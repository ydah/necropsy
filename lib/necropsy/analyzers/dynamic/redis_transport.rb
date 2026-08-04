# frozen_string_literal: true

require 'openssl'
require 'socket'

module Necropsy
  module Analyzers
    module Dynamic
      class RedisCommandError < StandardError; end

      class RedisTransport
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
          timeout = [limits.connect_timeout, deadline.remaining].min
          @tcp_socket = Socket.tcp(uri.host, uri.port || 6379, connect_timeout: timeout)
          apply_socket_timeout
          @socket = uri.scheme == 'rediss' ? connect_tls : tcp_socket
          deadline.check!
          self
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
          apply_socket_timeout
          socket.write(redis_command(parts))
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
          ssl_socket.connect
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

          apply_socket_timeout
          chunk = socket.readpartial([4096, remaining].min)
          @response_bytes += chunk.bytesize
          @read_buffer << chunk
        rescue EOFError
          domain_error('Redis closed the connection while reading a response')
        end

        def apply_socket_timeout
          seconds = [limits.read_timeout, deadline.remaining].min
          timeout = [seconds.to_i, ((seconds % 1) * 1_000_000).to_i].pack('l_2')
          tcp_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeout)
          tcp_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, timeout)
        end

        def domain_error(message)
          raise Error, redactor.redact(message), cause: nil
        end
      end
    end
  end
end
