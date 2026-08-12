# frozen_string_literal: true

RSpec.describe Necropsy::SemanticsMatrix do
  subject(:matrix) { described_class.new.to_h }

  it 'classifies every Prism node exactly once for the running Prism version' do
    runtime_nodes = Prism.constants.filter_map do |name|
      value = Prism.const_get(name)
      name.to_s if value.is_a?(Class) && value < Prism::Node
    end.sort
    entries = matrix.fetch('prism_nodes')

    expect(entries.map { |entry| entry.fetch('name') }).to eq(runtime_nodes)
    expect(entries.map { |entry| entry.fetch('name') }.uniq).to eq(runtime_nodes)
    expect(entries.map { |entry| entry.fetch('status') }.uniq - described_class::STATUSES).to be_empty
  end

  it 'makes an unreviewed future node unsupported by default' do
    original_constants = Prism.constants
    stub_const('Prism::FutureSemanticNode', Class.new(Prism::Node))
    allow(Prism).to receive(:constants).and_return(original_constants + [:FutureSemanticNode])

    entry = described_class.new.to_h.fetch('prism_nodes').find { |item| item['name'] == 'FutureSemanticNode' }
    expect(entry).to include('status' => 'unsupported')
  end

  it 'publishes reviewed Ruby hook and Rails DSL coverage' do
    expect(matrix.fetch('ruby_hooks').map { |entry| entry.fetch('name') }).to match_array(
      Necropsy::Confidence::Scorer::RUBY_HOOKS
    )
    expect(matrix.fetch('rails_dsl')).to include(
      include('name' => 'before_action', 'family' => 'callback', 'status' => 'partial'),
      include('name' => 'resources', 'family' => 'route', 'status' => 'partial'),
      include('name' => 'belongs_to', 'family' => 'generated_method', 'status' => 'partial')
    )
  end
end
