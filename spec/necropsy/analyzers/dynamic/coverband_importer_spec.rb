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

  it 'raises a domain error for a missing local source' do
    graph = graph_with(nodes: [])

    with_project do |root|
      expect do
        described_class.new('source' => 'missing.yml').analyze(graph, project_for(root))
      end.to raise_error(Necropsy::Error, /Coverband source does not exist/)
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

    it 'reports a clean error when Redis disconnects mid-response' do
      socket = instance_double(TCPSocket)
      allow(socket).to receive(:read).with(1).and_return(nil)
      loader.instance_variable_set(:@socket, socket)

      expect { loader.send(:read_response) }.to raise_error(Necropsy::Error, /closed the connection/)
    end

    it 'sends the ACL username when one is present in the URL' do
      acl_loader = described_class.new(source: 'redis://app:secret@localhost/0', config: {})
      allow(acl_loader).to receive(:command)

      acl_loader.send(:authenticate)

      expect(acl_loader).to have_received(:command).with('AUTH', 'app', 'secret')
    end
  end
end
