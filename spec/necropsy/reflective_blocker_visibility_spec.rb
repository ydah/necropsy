# frozen_string_literal: true

RSpec.describe 'respond_to? private reflection safety' do
  def analyze_reflection(argument:, limit:)
    handlers = 5.times.map do |index|
      "class Handler#{index}; private; def hidden; end; end"
    end.join("\n")
    invocation = argument ? "receiver.respond_to?(:hidden, #{argument})" : 'receiver.respond_to?(:hidden)'
    source = <<~RUBY
      #{handlers}
      class Caller
        def run(receiver, flag = nil)
          #{invocation}
        end
      end
    RUBY
    config = {
      cache: { enabled: false },
      entry_points: { extra: ['Caller#run'] },
      resolution: { ambiguity_limit: limit }
    }

    with_project(files: { 'app/reflection.rb' => source }, config: config) do |root|
      return Necropsy::Runner.new(root: root).analyze
    end
  end

  def hidden_findings(report)
    report.findings.select { |finding| finding.node.name == 'hidden' }
  end

  def hidden_reference(report)
    report.graph.call_sites.find do |site|
      site.message == 'hidden' && site.metadata['original_message'] == 'respond_to?'
    end
  end

  def hidden_blocker(report)
    report.graph.blockers.find do |blocker|
      blocker.message == 'hidden' && blocker.metadata['original_message'] == 'respond_to?'
    end
  end

  {
    'literal true' => ['true', true],
    'a truthy string literal' => ['"yes"', true],
    'a truthy object literal' => ['{}', true],
    'a runtime flag' => %w[flag unknown]
  }.each do |description, (argument, expected_state)|
    it "blocks private targets safely for #{description}" do
      limited = analyze_reflection(argument: argument, limit: 4)
      unlimited = analyze_reflection(argument: argument, limit: 'unlimited')
      limited_targets = hidden_findings(limited)
      unlimited_targets = hidden_findings(unlimited)

      expect(hidden_reference(limited).metadata['include_private']).to eq(expected_state)
      expect(hidden_blocker(limited).metadata['include_private']).to eq(expected_state)
      expect(limited_targets.length).to eq(5)
      expect(limited_targets).to all(have_attributes(classification: :blocked, confidence: :low))
      expect(unlimited_targets).to eq([])

      limited_unreachable = limited_targets.select { |finding| finding.classification == :unreachable }.to_set(&:node)
      unlimited_unreachable = unlimited_targets.select { |finding| finding.classification == :unreachable }.to_set(&:node)
      limited_high = limited_targets.select { |finding| finding.at_least?(:high) }.to_set(&:node)
      unlimited_high = unlimited_targets.select { |finding| finding.at_least?(:high) }.to_set(&:node)
      expect(limited_unreachable).to be_subset(unlimited_unreachable)
      expect(limited_high).to be_subset(unlimited_high)
    end
  end

  {
    'an absent second argument' => nil,
    'literal false' => 'false',
    'literal nil' => 'nil'
  }.each do |description, argument|
    it "does not match private targets for #{description}" do
      report = analyze_reflection(argument: argument, limit: 4)
      targets = hidden_findings(report)

      expect(hidden_reference(report).metadata['include_private']).to eq(false)
      expect(hidden_blocker(report).metadata['include_private']).to eq(false)
      expect(targets.length).to eq(5)
      expect(targets).to all(have_attributes(classification: :unreachable))
      expect(targets).to all(satisfy { |finding| finding.blockers.empty? })
    end
  end
end
