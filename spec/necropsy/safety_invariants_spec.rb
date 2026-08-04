# frozen_string_literal: true

require 'timeout'

class SafetyInvariantAnalyzer < Necropsy::Analyzer
  def initialize(result: Necropsy::AnalyzerResult.empty, failure: nil, name: :safety_invariant, kind: :static)
    @result = result
    @failure = failure
    @name = name
    @kind = kind
  end

  def analyze(*)
    raise failure if failure

    result
  end

  def profile
    Necropsy::AnalyzerProfile.new(name: name, kind: kind, soundness: :conservative, description: 'safety fixture')
  end

  private

  attr_reader :result, :failure, :name, :kind
end

RSpec.describe 'analysis safety invariants' do
  let(:base_config) { { cache: { enabled: false }, analyzers: { static: [] } } }

  def analyze(files:, config: base_config, analyzers: nil)
    with_project(files: files, config: config) do |root|
      return Necropsy::Runner.new(root: root, analyzers: analyzers).analyze
    end
  end

  def edge_result(caller_id, callee_id)
    analyzer_result(edge_evidences: [
                      Necropsy::EdgeEvidence.new(
                        caller_id: caller_id,
                        callee_id: callee_id,
                        evidence: evidence(analyzer: :safety_edge)
                      )
                    ])
  end

  def blocker_result(scope_kind:, scope_value:)
    analyzer_result(blockers: [
                      Necropsy::Blocker.new(
                        kind: :unknown_dispatch,
                        scope_kind: scope_kind,
                        scope_value: scope_value,
                        source: :safety_scope,
                        reason: 'safety fixture unresolved dispatch',
                        metadata: { 'caller_domain' => 'runtime' }
                      )
                    ])
  end

  it 'does not add candidates when an entry point is added' do
    files = { 'lib/entry.rb' => 'class SafetyEntry; def run = helper; def helper = :ok; end' }
    before = analyze(files: files)
    after = analyze(files: files, config: base_config.merge(entry_points: { extra: ['SafetyEntry#run'] }))

    expect(after).to preserve_candidate_safety_from(before).for_invariant('entry point addition')
  end

  it 'does not add candidates when a may-edge is added' do
    files = { 'lib/edge.rb' => 'class SafetyEdge; def run = :ok; def target = :ok; end' }
    config = base_config.merge(entry_points: { extra: ['SafetyEdge#run'] })
    before = analyze(files: files, config: config, analyzers: [SafetyInvariantAnalyzer.new])
    after = analyze(
      files: files,
      config: config,
      analyzers: [SafetyInvariantAnalyzer.new(result: edge_result('SafetyEdge#run', 'SafetyEdge#target'))]
    )

    expect(after).to preserve_candidate_safety_from(before).for_invariant('may-edge addition')
  end

  it 'does not add candidates when an unknown scope expands' do
    files = {
      'lib/handlers.rb' => <<~RUBY
        module Billing
          class Handler
            def call = :billing
          end
        end
        module Shipping
          class Handler
            def call = :shipping
          end
        end
      RUBY
    }
    scoped = SafetyInvariantAnalyzer.new(result: blocker_result(scope_kind: :namespace, scope_value: 'Billing'))
    global = SafetyInvariantAnalyzer.new(result: blocker_result(scope_kind: :global, scope_value: '*'))
    before = analyze(files: files, analyzers: [scoped])
    after = analyze(files: files, analyzers: [global])

    expect(after).to preserve_candidate_safety_from(before).for_invariant('unknown scope expansion')
  end

  it 'does not add candidates when a parse failure loses a cross-file call' do
    target = "class SafetyParseTarget\n  def used = :ok\n  def dead = :ok\nend\n"
    valid_caller = "class SafetyParseCaller\n  def run = SafetyParseTarget.new.used\nend\n"
    broken_caller = "class SafetyParseCaller\n  def run\n    SafetyParseTarget.new.\n  end\nend\n"
    config = { cache: { enabled: false }, entry_points: { extra: ['SafetyParseCaller#run'] } }
    before = analyze(files: { 'lib/caller.rb' => valid_caller, 'lib/target.rb' => target }, config: config)
    after = analyze(files: { 'lib/caller.rb' => broken_caller, 'lib/target.rb' => target }, config: config)

    expect(after).to preserve_candidate_safety_from(before).for_invariant('parse failure addition')
    expect(after.findings.find { |finding| finding.node.id == 'SafetyParseTarget#used' }).to have_attributes(
      classification: :blocked,
      blockers: include(have_attributes(kind: :parse_incomplete, scope_kind: :global))
    )
  end

  it 'turns analyzer failures and timeouts into global blockers without adding candidates' do
    files = {
      'lib/failure.rb' => <<~RUBY,
        class SafetyFailure
          def public_candidate = :ok
          private def private_candidate = :ok
        end
      RUBY
      'spec/failure_spec.rb' => 'class SafetyTestOnly; def ignored = :ok; end'
    }

    [RuntimeError.new('fixture failure'), Timeout::Error.new('fixture timeout')].each do |failure|
      before = analyze(files: files, analyzers: [SafetyInvariantAnalyzer.new])
      after = analyze(files: files, analyzers: [SafetyInvariantAnalyzer.new(failure: failure)])
      blocker = after.graph.blockers.find { |candidate| candidate.kind == :analyzer_failure }

      expect(after).to preserve_candidate_safety_from(before).for_invariant("analyzer #{failure.class}")
      expect(blocker).to have_attributes(scope_kind: :global, scope_value: '*', suggested_action: :fix_analyzer)
      expect(blocker.metadata).to include(
        'analyzer' => 'safety_invariant',
        'error_class' => failure.class.name,
        'error_message' => failure.message
      )
      expect(after.findings).to all(
        have_attributes(classification: :blocked, blockers: include(blocker))
      )
    end
  end

  it 'does not intercept process-ending analyzer exceptions' do
    analyzer = SafetyInvariantAnalyzer.new(failure: SystemExit.new(7))

    expect do
      analyze(files: { 'lib/exit.rb' => 'class SafetyExit; def candidate = :ok; end' }, analyzers: [analyzer])
    end.to raise_error(SystemExit) { |error| expect(error.status).to eq(7) }
  end

  it 'removes an observed execution from the candidate set' do
    files = { 'lib/observed.rb' => 'class SafetyObserved; def called = :ok; end' }
    observed = analyzer_result(alive_evidences: [
                                 Necropsy::AliveEvidence.new(
                                   node_id: 'SafetyObserved#called',
                                   evidence: evidence(analyzer: :safety_observation, kind: :alive)
                                 )
                               ])
    before = analyze(files: files, analyzers: [SafetyInvariantAnalyzer.new])
    after = analyze(
      files: files,
      analyzers: [SafetyInvariantAnalyzer.new(result: observed, name: :safety_observation, kind: :dynamic)]
    )

    expect(SafetyInvariantMatcher.candidate_ids(before)).to include('SafetyObserved#called')
    expect(after).to preserve_candidate_safety_from(before).for_invariant('observed execution addition')
    expect(SafetyInvariantMatcher.candidate_ids(after)).not_to include('SafetyObserved#called')
  end

  it 'keeps candidate sets identical across file order and cache modes' do
    files = {
      'lib/first.rb' => 'class SafetyFirst; def run = SafetySecond.new.call; end',
      'lib/second.rb' => 'class SafetySecond; def call = :ok; def dead = :ok; end'
    }

    with_project(files: files, config: base_config) do |root|
      uncached = Necropsy::Runner.new(root: root).analyze
      write_project_file(root, '.necropsy.yml', base_config.merge(cache: { enabled: true }).to_yaml)
      allow_any_instance_of(Necropsy::Project).to receive(:ruby_files).and_wrap_original do |method|
        method.call.reverse
      end
      reversed_cold = Necropsy::Runner.new(root: root).analyze
      reversed_warm = Necropsy::Runner.new(root: root).analyze

      expect(reversed_cold).to preserve_candidate_safety_from(uncached)
        .for_invariant('file discovery order').with_equal_sets
      expect(reversed_warm).to preserve_candidate_safety_from(reversed_cold)
        .for_invariant('cache cold/warm').with_equal_sets
    end
  end

  it 'does not add high or other candidates when the ambiguity limit shrinks' do
    handlers = 5.times.map { |index| "class SafetyHandler#{index}; def call = :ok; end" }.join("\n")
    files = { 'lib/ambiguity.rb' => "#{handlers}\nclass SafetyCaller; def run(handler) = handler.call; end\n" }
    common = { cache: { enabled: false }, entry_points: { extra: ['SafetyCaller#run'] } }
    before = analyze(files: files, config: common.merge(resolution: { ambiguity_limit: 'unlimited' }))
    after = analyze(files: files, config: common.merge(resolution: { ambiguity_limit: 4 }))

    expect(after).to preserve_candidate_safety_from(before).for_invariant('ambiguity limit reduction')
  end
end
