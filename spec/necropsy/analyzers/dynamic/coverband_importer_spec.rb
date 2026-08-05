# frozen_string_literal: true

RSpec.describe Necropsy::Analyzers::Dynamic::CoverbandImporter do
  it 'marks methods alive from explicit node ids' do
    live = node('Sample#live', file: 'app/sample.rb', line: 5, end_line: 7)
    dead = node('Sample#dead', file: 'app/sample.rb', line: 10, end_line: 12)
    graph = graph_with(nodes: [live, dead])
    payload = { 'nodes' => [live.id], 'observation' => { 'days' => 30 } }

    with_project(files: { 'coverband.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([live.id])
      emitted = result.alive_evidences.first.evidence
      expect(emitted).to have_attributes(
        grade: :observed,
        producer: :coverband,
        producer_version: Necropsy::VERSION,
        relation: :execution
      )
      expect(emitted.source).to include('type' => 'coverband', 'node_reference' => live.id)
      expect(result.evidences).to eq([emitted])
      expect(result.resolutions).to eq([])
      expect(described_class.new({}).profile).to have_attributes(
        version: Necropsy::VERSION,
        assumptions: %w[line_execution_mapping positive_observations_only]
      )
      expect(result.observation.fetch('coverband')).to include(
        'days' => 30,
        'positive_evidence_policy' => 'alive_only',
        'source_revision_status' => 'unknown'
      )
    end
  end

  it 'preserves unmatched explicit node ids for graph diagnostics' do
    graph = graph_with(nodes: [node('Sample#live')])

    with_project(files: { 'coverband.yml' => { 'nodes' => ['Other#live'] }.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq(['Other#live'])
    end
  end

  it 'preserves malformed structured references for graph diagnostics' do
    graph = graph_with(nodes: [node('Sample#live')])
    reference = { 'file' => 'app/sample.rb', 'line' => 3 }
    payload = { 'node_references' => [reference] }

    with_project(files: { 'coverband.json' => JSON.generate(payload) }) do |root|
      result = described_class.new('source' => 'coverband.json').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([reference])
      expect(result.observation.dig('coverband', 'malformed_references')).to eq(
        [{ 'kind' => 'node', 'reference' => reference }]
      )
    end
  end

  it 'maps line-count arrays and hashes back to methods by relative file' do
    first = node('Sample#first', file: 'app/sample.rb', line: 2, end_line: 4)
    second = node('Sample#second', file: 'app/sample.rb', line: 8, end_line: 10)
    graph = graph_with(nodes: [first, second])
    payload = {
      'files' => {
        'app/sample.rb' => [0, 1, 0, 0, 0, 0, 0, 2],
        '/repo/app/other.rb' => { '9' => 1 }
      }
    }

    with_project(files: { 'coverband.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first.id, second.id)
    end
  end

  it 'accepts root-level file coverage maps without a files wrapper' do
    live = node('Sample#live', file: 'app/sample.rb', line: 3, end_line: 3)
    graph = graph_with(nodes: [live])

    with_project(files: { 'coverband.yml' => { './app/sample.rb' => { '3' => 1 } }.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([live.id])
    end
  end

  it 'maps one executed span to every matching physical definition and records ambiguity' do
    first = node(
      'Sample#run', definition_id: 'def:v1:first', body_digest: 'first', ordinal: 1,
                    file: 'app/sample.rb', line: 3, end_line: 5
    )
    second = node(
      'Sample#run', definition_id: 'def:v1:second', body_digest: 'second', ordinal: 1,
                    file: 'app/sample.rb', line: 3, end_line: 6
    )
    graph = graph_with(nodes: [second, first])

    with_project(files: { 'coverband.yml' => { 'files' => { 'app/sample.rb' => [3] } }.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first.graph_id, second.graph_id)
      expect(result.observation.dig('coverband', 'line_ambiguities')).to contain_exactly(
        'file' => 'app/sample.rb', 'line' => 3, 'definition_ids' => [first.graph_id, second.graph_id].sort
      )
    end
  end

  it 'merges every deterministic suffix match instead of using the first coverage path' do
    first = node('Sample#first', file: 'app/sample.rb', line: 2, end_line: 2)
    second = node('Sample#second', file: 'app/sample.rb', line: 8, end_line: 8)
    graph = graph_with(nodes: [first, second])
    payload = {
      'files' => {
        '/first/root/app/sample.rb' => [2],
        '/second/root/app/sample.rb' => [8]
      }
    }

    with_project(files: { 'coverband.yml' => payload.to_yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to contain_exactly(first.graph_id, second.graph_id)
      expect(result.observation.dig('coverband', 'path_ambiguities')).to contain_exactly(
        'file' => 'app/sample.rb',
        'coverage_paths' => ['/first/root/app/sample.rb', '/second/root/app/sample.rb']
      )
    end
  end

  it 'raises a domain error for a missing local source' do
    graph = graph_with(nodes: [])

    with_project do |root|
      expect do
        described_class.new('source' => 'missing.yml').analyze(graph, project_for(root))
      end.to raise_error(Necropsy::Error, /Coverband source does not exist/)
    end
  end

  it 'preserves YAML alias support for local files' do
    live = node('Sample#live')
    graph = graph_with(nodes: [live])
    yaml = <<~YAML
      nodes: &executed
        - #{live.id}
      executed: *executed
    YAML

    with_project(files: { 'coverband.yml' => yaml }) do |root|
      result = described_class.new('source' => 'coverband.yml').analyze(graph, project_for(root))

      expect(result.alive_evidences.map(&:node_id)).to eq([live.id])
    end
  end

  describe Necropsy::Analyzers::Dynamic::RedisPayloadLoader do
    subject(:loader) { described_class.new(source: source, config: {}) }

    let(:source) { 'redis://localhost/0' }

    it 'uses safe YAML as the only JSON fallback and rejects Marshal payloads' do
      expect(loader.send(:parse_payload, "---\nfiles:\n  app/sample.rb: [0, 1]\n")).to include('files')
      expect do
        loader.send(:parse_payload, Marshal.dump('unsafe'))
      end.to raise_error(Necropsy::Error, /Invalid Redis coverage payload/)
    end

    it 'rejects malformed JSON, YAML, and YAML aliases' do
      expect { loader.send(:parse_payload, '{]') }.to raise_error(Necropsy::Error, /Invalid Redis coverage payload/)
      expect do
        loader.send(:parse_payload, "files: &files\n  app/sample.rb: [1]\ncopy: *files\n")
      end.to raise_error(Necropsy::Error, /Invalid Redis coverage payload/)
    end

    it 'rejects payload nesting beyond the configured limit' do
      limited = described_class.new(source: source, config: { 'max_payload_depth' => 2 })

      expect do
        limited.send(:parse_payload, '{"files":{"app/sample.rb":{"lines":[1]}}}')
      end.to raise_error(Necropsy::Error, /nesting depth/)
    end

    it 'rejects excessive configured key counts before connecting' do
      limited = described_class.new(
        source: source,
        config: { 'keys' => %w[first second], 'max_keys' => 1 }
      )

      expect { limited.send(:keys) }.to raise_error(Necropsy::Error, /key count/)
    end

    it 'sends the ACL username when one is present in the URL' do
      acl_loader = described_class.new(source: 'redis://app:secret@localhost/0', config: {})
      allow(acl_loader).to receive(:command)

      acl_loader.send(:authenticate)

      expect(acl_loader).to have_received(:command).with('AUTH', 'app', 'secret')
    end

    it 'redacts URI credentials from connection exceptions' do
      secret_source = 'redis://app:s3cr%65t@redis.invalid/0'
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(
        SocketError, "failed #{secret_source} app s3cret s3cr%65t"
      )

      expect do
        described_class.new(source: secret_source, config: {}).load
      end.to raise_error(Necropsy::Error) { |error|
        expect(error.message).not_to include(secret_source, 'app', 's3cret', 's3cr%65t')
        expect(error.message).to include('[REDACTED]')
        expect(error.cause).to be_nil
      }
    end
  end

  describe Necropsy::Analyzers::Dynamic::RedisDeadline do
    it 'uses a monotonic total deadline across operations' do
      allow(Process).to receive(:clock_gettime).and_return(10.0, 10.5, 11.1)
      deadline = described_class.new(1.0)

      expect(deadline.remaining).to be_within(0.001).of(0.5)
      expect { deadline.check! }.to raise_error(Necropsy::Error, /total timeout/)
    end
  end

  describe Necropsy::Analyzers::Dynamic::RedisTransport do
    let(:limits) do
      Necropsy::Analyzers::Dynamic::RedisInputLimits.new(
        'max_bulk_bytes' => 4,
        'max_array_elements' => 2,
        'max_resp_depth' => 1
      )
    end
    let(:deadline) { Necropsy::Analyzers::Dynamic::RedisDeadline.new(60) }
    let(:redactor) { Necropsy::Analyzers::Dynamic::RedisCredentialRedactor.new('redis://localhost/0') }
    let(:uri) { URI('redis://localhost/0') }
    let(:transport) { described_class.new(uri: uri, limits: limits, deadline: deadline, redactor: redactor) }

    def attach_response(transport, response)
      remaining = response.dup
      socket = instance_double(Socket)
      allow(socket).to receive(:to_io).and_return(socket)
      allow(socket).to receive(:read_nonblock) do |length, exception:|
        expect(exception).to eq(false)
        remaining.empty? ? nil : remaining.slice!(0, length)
      end
      transport.instance_variable_set(:@socket, socket)
      transport.instance_variable_set(:@tcp_socket, socket)
    end

    it 'rejects oversized bulk strings before allocating them' do
      attach_response(transport, "$5\r\nhello\r\n")

      expect { transport.send(:read_response) }.to raise_error(Necropsy::Error, /bulk response exceeds/)
    end

    it 'bounds total response bytes even when no line terminator arrives' do
      byte_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new('max_response_bytes' => 4)
      bounded = described_class.new(uri: uri, limits: byte_limits, deadline: deadline, redactor: redactor)
      attach_response(bounded, '+unbounded')

      expect { bounded.send(:read_response) }.to raise_error(Necropsy::Error, /byte limit/)
    end

    it 'rejects excessive array elements and nesting' do
      attach_response(transport, "*3\r\n+one\r\n+two\r\n+three\r\n")
      expect { transport.send(:read_response) }.to raise_error(Necropsy::Error, /element limit/)

      nested = described_class.new(uri: uri, limits: limits, deadline: deadline, redactor: redactor)
      attach_response(nested, "*1\r\n*1\r\n+value\r\n")
      expect { nested.send(:read_response) }.to raise_error(Necropsy::Error, /nesting depth/)
    end

    it 'rejects invalid lengths, prefixes, and bulk terminators' do
      invalid_responses = ["$-2\r\n", "$nope\r\n", "?unknown\r\n", "$3\r\nabcXX"]

      invalid_responses.each do |response|
        invalid = described_class.new(uri: uri, limits: limits, deadline: deadline, redactor: redactor)
        attach_response(invalid, response)
        expect { invalid.send(:read_response) }.to raise_error(Necropsy::Error, /Redis/)
      end
    end

    it 'reports a bounded domain error when Redis disconnects mid-response' do
      attach_response(transport, '$3')

      expect { transport.send(:read_response) }.to raise_error(Necropsy::Error, /closed the connection/)
    end

    it 'requires peer verification and rejects an invalid certificate' do
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket)
      tcp_socket = instance_double(Socket)
      captured_context = nil
      allow(tcp_socket).to receive(:close)
      allow(ssl_socket).to receive(:sync_close=)
      allow(ssl_socket).to receive(:hostname=)
      allow(ssl_socket).to receive(:close)
      allow(ssl_socket).to receive(:connect_nonblock)
        .with(exception: false).and_raise(OpenSSL::SSL::SSLError, 'certificate verify failed')
      allow(OpenSSL::SSL::SSLSocket).to receive(:new) do |_socket, context|
        captured_context = context
        ssl_socket
      end

      secure = described_class.new(
        uri: URI('rediss://localhost/0'), limits: limits, deadline: deadline, redactor: redactor
      )
      allow(secure).to receive(:connect_tcp).and_return(tcp_socket)
      expect { secure.connect }.to raise_error(Necropsy::Error, /connect securely/)
      expect(captured_context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect(captured_context.cert_store).to be_a(OpenSSL::X509::Store)
    end

    it 'sets SNI and performs post-connect hostname verification' do
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket)
      tcp_socket = instance_double(Socket)
      allow(tcp_socket).to receive(:close)
      allow(ssl_socket).to receive(:sync_close=)
      allow(ssl_socket).to receive(:hostname=)
      allow(ssl_socket).to receive(:connect_nonblock).with(exception: false).and_return(ssl_socket)
      allow(ssl_socket).to receive(:close)
      allow(ssl_socket).to receive(:post_connection_check)
        .with('example.test').and_raise(OpenSSL::SSL::SSLError, 'hostname mismatch')
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl_socket)

      secure = described_class.new(
        uri: URI('rediss://example.test/0'), limits: limits, deadline: deadline, redactor: redactor
      )
      allow(secure).to receive(:connect_tcp).and_return(tcp_socket)
      expect { secure.connect }.to raise_error(Necropsy::Error, /connect securely/)
      expect(ssl_socket).to have_received(:hostname=).with('example.test')
      expect(ssl_socket).to have_received(:post_connection_check).with('example.test')
    end

    it 'enforces read and total deadlines on a stalled real socket' do
      [
        [{ 'read_timeout' => 0.03, 'total_timeout' => 1.0 }, /read timeout/],
        [{ 'read_timeout' => 1.0, 'total_timeout' => 0.03 }, /total timeout/]
      ].each do |config, message|
        reader, writer = Socket.pair(:UNIX, :STREAM, 0)
        stalled_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new(config)
        stalled_deadline = Necropsy::Analyzers::Dynamic::RedisDeadline.new(stalled_limits.total_timeout)
        stalled = described_class.new(uri: uri, limits: stalled_limits, deadline: stalled_deadline, redactor: redactor)
        stalled.instance_variable_set(:@socket, reader)
        stalled.instance_variable_set(:@tcp_socket, reader)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { stalled.send(:read_response) }.to raise_error(Necropsy::Error, message)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be_between(0.01, 0.5)
      ensure
        reader&.close
        writer&.close
      end
    end

    it 'enforces the IO deadline when a real socket cannot accept more writes' do
      writer, reader = Socket.pair(:UNIX, :STREAM, 0)
      payload = 'x' * 65_536
      loop do
        result = writer.write_nonblock(payload, exception: false)
        break if result == :wait_writable
      end
      stalled_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new(
        'read_timeout' => 0.03, 'total_timeout' => 1.0
      )
      stalled = described_class.new(
        uri: uri,
        limits: stalled_limits,
        deadline: Necropsy::Analyzers::Dynamic::RedisDeadline.new(stalled_limits.total_timeout),
        redactor: redactor
      )
      stalled.instance_variable_set(:@socket, writer)
      stalled.instance_variable_set(:@tcp_socket, writer)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { stalled.send(:write_all, 'PING') }.to raise_error(Necropsy::Error, /write timeout/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be_between(0.01, 0.5)
    ensure
      writer&.close
      reader&.close
    end

    it 'enforces the total deadline while a TLS handshake is stalled' do
      tcp_socket, peer = Socket.pair(:UNIX, :STREAM, 0)
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket)
      stalled_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new(
        'connect_timeout' => 1.0, 'total_timeout' => 0.03
      )
      stalled_deadline = Necropsy::Analyzers::Dynamic::RedisDeadline.new(stalled_limits.total_timeout)
      allow(ssl_socket).to receive(:sync_close=)
      allow(ssl_socket).to receive(:hostname=)
      allow(ssl_socket).to receive(:connect_nonblock).with(exception: false).and_return(:wait_readable)
      allow(ssl_socket).to receive(:to_io).and_return(tcp_socket)
      allow(ssl_socket).to receive(:close)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl_socket)
      secure = described_class.new(
        uri: URI('rediss://localhost/0'), limits: stalled_limits, deadline: stalled_deadline, redactor: redactor
      )
      allow(secure).to receive(:connect_tcp).and_return(tcp_socket)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { secure.connect }.to raise_error(Necropsy::Error, /total timeout/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      expect(elapsed).to be_between(0.01, 0.5)
    ensure
      tcp_socket&.close
      peer&.close
    end

    it 'bounds stalled address resolution by the connect and total deadlines' do
      [
        [{ 'connect_timeout' => 0.03, 'total_timeout' => 1.0 }, /resolution timeout/],
        [{ 'connect_timeout' => 1.0, 'total_timeout' => 0.03 }, /total timeout/]
      ].each do |config, message|
        stalled_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new(config)
        stalled = described_class.new(
          uri: uri,
          limits: stalled_limits,
          deadline: Necropsy::Analyzers::Dynamic::RedisDeadline.new(stalled_limits.total_timeout),
          redactor: redactor
        )
        allow(Addrinfo).to receive(:getaddrinfo) { sleep 1 }
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { stalled.connect }.to raise_error(Necropsy::Error, message)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be_between(0.01, 0.5)
      end
    end

    it 'checks write and total deadlines between positive partial writes' do
      [
        [{ 'read_timeout' => 0.03, 'total_timeout' => 1.0 }, /write timeout/],
        [{ 'read_timeout' => 1.0, 'total_timeout' => 0.03 }, /total timeout/]
      ].each do |config, message|
        attempts = 0
        partial_writer = instance_double(Socket)
        allow(partial_writer).to receive(:write_nonblock) do |_value, exception:|
          expect(exception).to eq(false)
          attempts += 1
          sleep 0.012
          1
        end
        stalled_limits = Necropsy::Analyzers::Dynamic::RedisInputLimits.new(config)
        stalled = described_class.new(
          uri: uri,
          limits: stalled_limits,
          deadline: Necropsy::Analyzers::Dynamic::RedisDeadline.new(stalled_limits.total_timeout),
          redactor: redactor
        )
        stalled.instance_variable_set(:@socket, partial_writer)
        stalled.instance_variable_set(:@tcp_socket, partial_writer)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { stalled.send(:write_all, 'partial') }.to raise_error(Necropsy::Error, message)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        expect(elapsed).to be_between(0.01, 0.5)
        expect(attempts).to be_between(1, 6)
      end
    end
  end
end
