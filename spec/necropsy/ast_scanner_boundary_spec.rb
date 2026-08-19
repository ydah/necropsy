# frozen_string_literal: true

RSpec.describe Necropsy::AstScanner::FileScanner do
  it 'owns per-file parsing, root setup, and visitor orchestration' do
    with_project(files: { 'lib/example.rb' => "class Example; def run; end; end\n" }) do |root|
      project = project_for(root)
      file = File.join(root, 'lib/example.rb')
      state = Struct.new(:file_statuses).new({})
      root_node = instance_double(Necropsy::Node, graph_id: 'root-graph-id')
      emitter = instance_double(Necropsy::AstScanner::DefinitionEmitter)
      flow_result = instance_double(Proc)
      visitor = instance_double(Proc)

      expect(emitter).to receive(:emit).with(
        hash_including(
          symbol_id: 'file:lib/example.rb',
          kind: :block_entry,
          defined_via: :file
        )
      ).and_return(root_node)
      expect(flow_result).to receive(:call) do |node, context|
        expect(node).to be_a(Prism::ProgramNode)
        expect(context.current_caller_id).to eq('root-graph-id')
        :flow
      end
      expect(visitor).to receive(:call) do |node, context|
        expect(node).to be_a(Prism::ProgramNode)
        expect(context.flow_result).to eq(:flow)
      end

      described_class.new(
        project: project,
        file: file,
        state: state,
        definition_emitter: emitter,
        flow_result: flow_result,
        visit: visitor,
        record_parse_errors: ->(*) { raise 'unexpected parse error' },
        record_source_failure: ->(*) { raise 'unexpected source failure' }
      ).scan

      expect(state.file_statuses).to eq('lib/example.rb' => :complete)
    end
  end
end

RSpec.describe Necropsy::AstScanner::DefinitionEmitter do
  it 'owns deterministic definition identity allocation and ledger append' do
    state_class = Struct.new(:nodes, :definition_ordinals)
    state = state_class.new([], Hash.new(0))
    context = Necropsy::AstScanner::Context.new(relative_file: 'lib/example.rb', test: false, visibility: :public)
    source_node = Prism.parse("def run; end\n").value.statements.body.first
    emitter = described_class.new(state: state)

    definitions = 2.times.map do
      emitter.emit(
        symbol_id: 'Example#run',
        kind: :instance_method,
        source_node: source_node,
        context: context,
        defined_via: :def,
        owner: 'Example',
        name: 'run'
      )
    end

    expect(definitions.map(&:ordinal)).to eq([1, 2])
    expect(definitions.map(&:graph_id).uniq.length).to eq(2)
    expect(state.nodes).to eq(definitions)
  end
end
