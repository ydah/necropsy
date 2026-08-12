# frozen_string_literal: true

RSpec.describe 'deterministic Prism AST shape fuzzing' do
  def shapes
    [
      'value &&= -> { helper }',
      'value ||= { key: helper, **extra }',
      'case value; in { key: }; helper; else; fallback; end',
      'begin; helper; rescue StandardError; fallback; ensure; cleanup; end',
      '[value].filter_map { _1&.helper }',
      'for item in [value]; item&.helper; end',
      'value&.public_send(message, *args, **kwargs, &block)',
      '->(item = helper) { item }.call',
      'class << self; private def nested = helper; end',
      'defined?(value.helper) ? helper : fallback'
    ]
  end

  def fuzz_files(seed:, count: 80)
    random = Random.new(seed)
    count.times.to_h do |index|
      shape = shapes.fetch(random.rand(shapes.length))
      ["lib/fuzz_#{index}.rb", <<~RUBY]
        class Fuzz#{index}
          def exercise(value = nil, message = :helper, args = [], kwargs = {}, block = nil, extra = {})
            #{shape}
          end
          def helper = :ok
          def fallback = :fallback
          def cleanup = nil
        end
      RUBY
    end
  end

  it 'does not crash, violate graph invariants, or grow without a deterministic bound' do
    expect(fuzz_files(seed: 14_091)).to eq(fuzz_files(seed: 14_091))

    with_project(files: fuzz_files(seed: 14_091), config: { cache: { enabled: false } }) do |root|
      report = Necropsy::Runner.new(root: root).analyze

      expect { Necropsy::GraphSelfCheck.new(report).validate! }.not_to raise_error
      expect(report.graph.nodes.length).to be < 1_000
      expect(report.graph.call_sites.length).to be < 2_000
      expect(JSON.generate(report.to_h(include_graph: true)).bytesize).to be < 10_000_000
    end
  end
end
