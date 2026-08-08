# frozen_string_literal: true

RSpec.describe 'core Ruby method lookup conformance' do
  def lookup(graph, caller:, message:, receiver_kind:, receiver_name: nil, metadata: {})
    site = call_site(
      caller_id: caller.graph_id,
      message: message,
      receiver_kind: receiver_kind,
      receiver_name: receiver_name,
      metadata: metadata
    )
    graph.method_lookup(site)
  end

  it 'uses prepend, class, reverse include, and superclass order for instance dispatch' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    targets = %w[First Second Prefix Host Parent].map do |owner|
      node("#{owner}#render", owner: owner, name: 'render')
    end
    infos = [
      class_info('First', kind: :module),
      class_info('Second', kind: :module),
      class_info('Prefix', kind: :module),
      class_info('Parent'),
      class_info('Host', superclass: 'Parent', includes: %w[First Second], prepends: ['Prefix'])
    ]
    graph = graph_with(nodes: [caller, *targets], class_infos: infos)

    result = lookup(
      graph,
      caller: caller,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Host',
      metadata: { 'receiver_candidates' => ['Host'] }
    )

    expect(result).to be_complete
    expect(result.lookup_chain).to eq(%w[Prefix Host Second First Parent])
    expect(result.targets.map(&:symbol_id)).to eq(['Prefix#render'])
    expect(result.rejected_targets.map(&:definition_id)).to include(
      *targets.drop(3).map(&:graph_id)
    )
  end

  it 'preserves Ruby argument precedence within multi-module include, prepend, and extend calls' do
    source = <<~RUBY
      module FirstArgument
        def render = :first
      end
      module SecondArgument
        def render = :second
      end
      class IncludedHost
        include FirstArgument, SecondArgument
      end
      class PrependedHost
        prepend FirstArgument, SecondArgument
      end
      class ExtendedHost
        extend FirstArgument, SecondArgument
      end
    RUBY

    with_project(files: { 'app/multi_relation.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'FirstArgument#render' }
      included = lookup(graph, caller: caller, message: 'render', receiver_kind: :instance,
                               receiver_name: 'IncludedHost')
      prepended = lookup(graph, caller: caller, message: 'render', receiver_kind: :instance,
                                receiver_name: 'PrependedHost')
      extended = lookup(graph, caller: caller, message: 'render', receiver_kind: :constant,
                               receiver_name: 'ExtendedHost')

      expect(included.lookup_chain.first(3)).to eq(%w[IncludedHost FirstArgument SecondArgument])
      expect(prepended.lookup_chain.first(3)).to eq(%w[FirstArgument SecondArgument PrependedHost])
      expect(extended.lookup_chain.first(3)).to eq(%w[ExtendedHost FirstArgument SecondArgument])
      expect([included, prepended, extended].map { |result| result.targets.map(&:symbol_id) }).to eq(
        Array.new(3, ['FirstArgument#render'])
      )
    end
  end

  it 'falls through the class, reverse includes, and superclass when earlier owners do not define the message' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    included = node('First#render', owner: 'First', name: 'render')
    parent = node('Parent#render', owner: 'Parent', name: 'render')
    graph = graph_with(
      nodes: [caller, included, parent],
      class_infos: [
        class_info('First', kind: :module),
        class_info('Second', kind: :module),
        class_info('Parent'),
        class_info('Host', superclass: 'Parent', includes: %w[First Second])
      ]
    )

    result = lookup(graph, caller: caller, message: 'render', receiver_kind: :instance, receiver_name: 'Host')

    expect(result).to be_complete
    expect(result.targets.map(&:symbol_id)).to eq(['First#render'])
    expect(result.rejected_targets.map(&:definition_id)).to include(parent.graph_id)
  end

  it 'resolves eigenclass methods, extended modules, and superclass singleton methods in order' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    own = node('Child.build', kind: :singleton_method, owner: 'Child', name: 'build')
    extension = node('FactoryMethods#build', owner: 'FactoryMethods', name: 'build')
    inherited = node('Parent.build', kind: :singleton_method, owner: 'Parent', name: 'build')
    infos = [
      class_info('FactoryMethods', kind: :module),
      class_info('Parent'),
      class_info('Child', superclass: 'Parent', extends: ['FactoryMethods'])
    ]

    graph = graph_with(nodes: [caller, own, extension, inherited], class_infos: infos)
    own_result = lookup(graph, caller: caller, message: 'build', receiver_kind: :constant, receiver_name: 'Child')
    expect(own_result.targets.map(&:symbol_id)).to eq(['Child.build'])

    graph = graph_with(nodes: [caller, extension, inherited], class_infos: infos)
    extended_result = lookup(graph, caller: caller, message: 'build', receiver_kind: :constant,
                                    receiver_name: 'Child')
    expect(extended_result.targets.map(&:symbol_id)).to eq(['FactoryMethods#build'])

    graph = graph_with(nodes: [caller, inherited], class_infos: infos)
    inherited_result = lookup(graph, caller: caller, message: 'build', receiver_kind: :constant,
                                     receiver_name: 'Child')
    expect(inherited_result.targets.map(&:symbol_id)).to eq(['Parent.build'])
  end

  it 'tracks eigenclass prepend/include relations and module_function singleton copies' do
    source = <<~RUBY
      module EigenPrefix
        def build = :prefix
      end
      module EigenExtension
        def build = :extension
      end
      class Parent
        def self.build = :parent
      end
      class Child < Parent
        class << self
          prepend EigenPrefix
          include EigenExtension
          def build = :child
        end
      end
      module Tools
        module_function
        def utility = :ok
      end
    RUBY

    with_project(files: { 'app/eigenclass.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |candidate| candidate.symbol_id == 'Child.build' }
      eigen = lookup(graph, caller: caller, message: 'build', receiver_kind: :constant, receiver_name: 'Child')
      utility = lookup(graph, caller: caller, message: 'utility', receiver_kind: :constant, receiver_name: 'Tools')
      child_info = scan.class_infos.find { |info| info.id == 'Child' }

      expect(child_info.singleton_prepends).to eq(['EigenPrefix'])
      expect(child_info.singleton_includes).to eq(['EigenExtension'])
      expect(eigen.lookup_chain).to eq(%w[EigenPrefix Child EigenExtension Parent Object])
      expect(eigen.targets.map(&:symbol_id)).to eq(['EigenPrefix#build'])
      expect(utility.targets.map(&:symbol_id)).to eq(['Tools.utility'])
      expect(utility).to be_complete
    end
  end

  it 'starts super lookup after the current implementation for instance and singleton methods' do
    instance_caller = node('Child#render', owner: 'Child', name: 'render')
    included = node('Decoration#render', owner: 'Decoration', name: 'render')
    parent = node('Parent#render', owner: 'Parent', name: 'render')
    singleton_caller = node('Child.build', kind: :singleton_method, owner: 'Child', name: 'build')
    extension = node('Factories#build', owner: 'Factories', name: 'build')
    graph = graph_with(
      nodes: [instance_caller, included, parent, singleton_caller, extension],
      class_infos: [
        class_info('Decoration', kind: :module),
        class_info('Factories', kind: :module),
        class_info('Parent'),
        class_info('Child', superclass: 'Parent', includes: ['Decoration'], extends: ['Factories'])
      ]
    )

    instance = lookup(graph, caller: instance_caller, message: 'render', receiver_kind: :super,
                             receiver_name: 'Child')
    singleton = lookup(graph, caller: singleton_caller, message: 'build', receiver_kind: :super,
                              receiver_name: 'Child')

    expect(instance.targets.map(&:symbol_id)).to eq(['Decoration#render'])
    expect(singleton.targets.map(&:symbol_id)).to eq(['Factories#build'])
    expect(instance).to be_complete
    expect(singleton).to be_complete
  end

  it 'keeps super from a reused module partial while retaining each known next implementation' do
    caller = node('Prefix#render', owner: 'Prefix', name: 'render')
    host = node('Host#render', owner: 'Host', name: 'render')
    other = node('OtherHost#render', owner: 'OtherHost', name: 'render')
    graph = graph_with(
      nodes: [caller, host, other],
      class_infos: [
        class_info('Prefix', kind: :module),
        class_info('Host', prepends: ['Prefix']),
        class_info('OtherHost', prepends: ['Prefix'])
      ]
    )

    result = lookup(graph, caller: caller, message: 'render', receiver_kind: :super,
                           receiver_name: 'Prefix')

    expect(result).to be_partial
    expect(result.targets.map(&:symbol_id)).to contain_exactly('Host#render', 'OtherHost#render')
    expect(result.rejected_targets).to eq([])
  end

  it 'resolves super from an extended module through each known singleton host chain' do
    caller = node('Factories#build', owner: 'Factories', name: 'build')
    parent = node('Parent.build', kind: :singleton_method, owner: 'Parent', name: 'build')
    graph = graph_with(
      nodes: [caller, parent],
      class_infos: [
        class_info('Factories', kind: :module),
        class_info('Parent'),
        class_info('Child', superclass: 'Parent', extends: ['Factories'])
      ]
    )

    result = lookup(graph, caller: caller, message: 'build', receiver_kind: :super,
                           receiver_name: 'Factories')

    expect(result).to be_partial
    expect(result.targets.map(&:symbol_id)).to eq(['Parent.build'])
    expect(result.lookup_chain).to include('Parent')
  end

  it 'rejects a private explicit target only when the lookup universe is complete' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    private_target = node('Host#secret', owner: 'Host', name: 'secret', visibility: :private)
    complete_graph = graph_with(
      nodes: [caller, private_target],
      class_infos: [class_info('Host')]
    )
    incomplete_graph = graph_with(nodes: [caller, private_target])

    complete = lookup(complete_graph, caller: caller, message: 'secret', receiver_kind: :instance,
                                      receiver_name: 'Host')
    incomplete = lookup(incomplete_graph, caller: caller, message: 'secret', receiver_kind: :instance,
                                          receiver_name: 'Host')

    expect(complete).to be_complete
    expect(complete.targets).to eq([])
    expect(complete.rejected_targets).to contain_exactly(
      have_attributes(definition_id: private_target.graph_id, reason: 'private_visibility')
    )
    expect(incomplete).not_to be_complete
    expect(incomplete.targets).to contain_exactly(private_target)
    expect(incomplete.rejected_targets).to eq([])
  end

  it 'rejects an arity mismatch only when receiver lookup and both signatures are complete' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Host#render', owner: 'Host', name: 'render')
    signature = {
      target.graph_id => {
        'complete' => true,
        'minimum_positionals' => 1,
        'maximum_positionals' => 1,
        'required_keywords' => [],
        'accepted_keywords' => [],
        'keyword_rest' => false
      }
    }
    site = call_site(
      caller_id: caller.graph_id,
      message: 'render',
      receiver_kind: :instance,
      receiver_name: 'Host',
      metadata: { 'arguments' => { 'complete' => true, 'positional_count' => 0, 'keywords' => [] } }
    )
    complete = graph_with(
      nodes: [caller, target], class_infos: [class_info('Host')], method_signatures: signature
    ).method_lookup(site)
    incomplete = graph_with(nodes: [caller, target], method_signatures: signature).method_lookup(site)

    expect(complete).to be_complete
    expect(complete.targets).to eq([])
    expect(complete.rejected_targets).to contain_exactly(
      have_attributes(definition_id: target.graph_id, reason: 'arity_mismatch')
    )
    expect(incomplete).not_to be_complete
    expect(incomplete.targets).to contain_exactly(target)
    expect(incomplete.rejected_targets).to eq([])
  end

  it 'keeps analyzer resolution status and rejections aligned with the shared lookup result' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Host#secret', owner: 'Host', name: 'secret', visibility: :private)
    site = call_site(
      caller_id: caller.graph_id,
      message: 'secret',
      receiver_kind: :instance,
      receiver_name: 'Host'
    )
    complete_graph = graph_with(
      nodes: [caller, target], call_sites: [site], class_infos: [class_info('Host')]
    )
    incomplete_graph = graph_with(nodes: [caller, target], call_sites: [site])
    analyzers = [Necropsy::Analyzers::Static::NameResolution.new, Necropsy::Analyzers::Static::CHA.new]

    complete = analyzers.map { |analyzer| analyzer.analyze(complete_graph, nil).resolutions.fetch(0).resolution }
    incomplete = analyzers.map { |analyzer| analyzer.analyze(incomplete_graph, nil).resolutions.fetch(0).resolution }

    expect(complete.map(&:status)).to eq(%i[complete complete])
    expect(complete.map(&:target_definition_ids)).to eq([[], []])
    expect(complete).to all(satisfy do |resolution|
      resolution.rejected_targets.one? && resolution.rejected_targets.first.reason == 'private_visibility'
    end)
    expect(incomplete.map(&:status)).to eq(%i[partial partial])
    expect(incomplete.map(&:target_definition_ids)).to eq([[target.graph_id], [target.graph_id]])
    expect(incomplete.flat_map(&:rejected_targets)).to eq([])
  end

  it 'does not add lookup targets when ancestry completeness is lost' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Host#render', owner: 'Host', name: 'render')
    site = call_site(caller_id: caller.graph_id, message: 'render', receiver_kind: :instance,
                     receiver_name: 'Host')
    complete_graph = graph_with(nodes: [caller, target], class_infos: [class_info('Host')])
    incomplete_graph = graph_with(
      nodes: [caller, target],
      class_infos: [class_info('Host', prepends: ['RuntimePrefix'])]
    )

    complete = complete_graph.method_lookup(site)
    incomplete = incomplete_graph.method_lookup(site)

    expect(complete.targets.map(&:graph_id)).to eq([target.graph_id])
    expect(incomplete.targets.map(&:graph_id)).to eq(complete.targets.map(&:graph_id))
    expect(incomplete).to be_partial
    expect(incomplete.rejected_targets).to eq([])
  end

  it 'keeps a prepended target partial when the dispatch owner has dynamic ancestry' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Prefix#render', owner: 'Prefix', name: 'render')
    graph = graph_with(
      nodes: [caller, target],
      class_infos: [class_info('Prefix', kind: :module), class_info('Host', prepends: ['Prefix'], dynamic: true)]
    )

    result = lookup(graph, caller: caller, message: 'render', receiver_kind: :instance,
                           receiver_name: 'Host')

    expect(result).to be_partial
    expect(result.targets).to eq([target])
    expect(result.rejected_targets).to eq([])
  end

  it 'does not reject visibility or arity when method_missing exists anywhere in the lookup chain' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    target = node('Host#secret', owner: 'Host', name: 'secret', visibility: :private)
    method_missing = node('Fallback#method_missing', owner: 'Fallback', name: 'method_missing')
    site = call_site(
      caller_id: caller.graph_id,
      message: 'secret',
      receiver_kind: :instance,
      receiver_name: 'Host',
      metadata: { 'arguments' => { 'complete' => true, 'positional_count' => 0, 'keywords' => [] } }
    )
    graph = graph_with(
      nodes: [caller, target, method_missing],
      class_infos: [class_info('Fallback', kind: :module, dynamic: true), class_info('Host', includes: ['Fallback'])],
      method_signatures: {
        target.graph_id => {
          'complete' => true, 'minimum_positionals' => 1, 'maximum_positionals' => 1,
          'required_keywords' => [], 'accepted_keywords' => [], 'keyword_rest' => false
        }
      }
    )

    result = graph.method_lookup(site)

    expect(result).to be_partial
    expect(result.targets).to eq([target])
    expect(result.rejected_targets).to eq([])
  end

  it 'keeps lookup output deterministic when definitions and class metadata arrive in different orders' do
    caller = node('Caller#run', owner: 'Caller', name: 'run')
    first = node('Mix#render', owner: 'Mix', name: 'render', definition_id: 'def:v1:b', line: 9)
    second = node('Mix#render', owner: 'Mix', name: 'render', definition_id: 'def:v1:a', line: 3)
    infos = [class_info('Host', includes: ['Mix']), class_info('Mix', kind: :module)]
    site = call_site(caller_id: caller.graph_id, message: 'render', receiver_kind: :instance,
                     receiver_name: 'Host')

    left = graph_with(nodes: [caller, first, second], class_infos: infos).method_lookup(site)
    right = graph_with(nodes: [second, caller, first], class_infos: infos.reverse).method_lookup(site)

    expect(left.to_h).to eq(right.to_h)
    expect(left.targets.map(&:graph_id)).to eq(%w[def:v1:a def:v1:b])
  end

  it 'records zsuper identity and semantic scope blockers for unsupported Ruby features' do
    source = <<~RUBY
      module Patch
        refine String do
          def decorated = self
        end
      end

      using Patch

      class Parent
        def render(value) = value
      end

      class Child < Parent
        def render(...)
          super
        end

        include Object.const_get('RuntimeMix')
        prepend Object.const_get('RuntimePrefix')
      end

      target = Child
      target.class_eval do
        def generated = true
      end
      eval(runtime_source)
    RUBY

    with_project(files: { 'app/lookup.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      child = scan.nodes.find { |candidate| candidate.symbol_id == 'Child#render' }
      super_site = scan.call_sites.find do |site|
        site.caller_id == child.graph_id && site.receiver_kind == :super
      end

      expect(super_site.message).to eq('render')
      expect(super_site.metadata).to include('super' => true, 'zsuper' => true)
      expect(scan.semantic_blockers.map(&:kind)).to include(
        :unsupported_refinement, :dynamic_ancestry, :variable_eval
      )
      expect(scan.semantic_blockers.map(&:scope_kind)).to all(satisfy { |kind| %i[owner namespace global].include?(kind) })
      expect(graph_for_scan(scan).blockers.map(&:kind)).to include(
        :unsupported_refinement, :dynamic_ancestry, :variable_eval
      )
      graph = graph_for_scan(scan)
      matching = graph.matching_blockers(child).map(&:kind)
      semantic = scan.semantic_blockers
      expect(matching).to include(:unsupported_refinement, :dynamic_ancestry, :variable_eval)
      expect(semantic.map(&:message)).to all(be_nil)
      expect(semantic.map { |blocker| blocker.metadata['semantic_operation'] }).to include(
        'refine', 'using', 'include', 'prepend', 'class_eval', 'eval'
      )
    end
  end

  it 'matches a constant-owner variable eval blocker to every candidate in that owner' do
    source = <<~RUBY
      class EvalTarget
        def first = true
        def second = true
      end
      class Unrelated
        def first = true
        EvalTarget.class_eval(runtime_source)
      end
    RUBY

    with_project(files: { 'app/eval.rb' => source }, config: { cache: { enabled: false } }) do |root|
      graph = graph_for_project(root)
      first = graph.nodes.values.find { |node| node.symbol_id == 'EvalTarget#first' }
      second = graph.nodes.values.find { |node| node.symbol_id == 'EvalTarget#second' }
      unrelated = graph.nodes.values.find { |node| node.symbol_id == 'Unrelated#first' }
      blocker = graph.blockers.find { |candidate| candidate.kind == :variable_eval }

      expect(blocker).to have_attributes(scope_kind: :owner, scope_value: 'EvalTarget', message: nil)
      expect(graph.matching_blockers(first)).to include(blocker)
      expect(graph.matching_blockers(second)).to include(blocker)
      expect(graph.matching_blockers(unrelated)).not_to include(blocker)
    end
  end

  it 'applies Ruby 3 keyword-to-positional conversion while preserving **nil rejection' do
    source = <<~RUBY
      class KeywordHost
        def options(options = {}) = options
        def no_keywords(**nil) = nil

        def run
          options(mode: :fast)
          no_keywords(mode: :fast)
        end
      end
    RUBY

    with_project(files: { 'app/keywords.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      caller = scan.nodes.find { |node| node.symbol_id == 'KeywordHost#run' }
      options_site = scan.call_sites.find { |site| site.caller_id == caller.graph_id && site.message == 'options' }
      no_keywords_site = scan.call_sites.find do |site|
        site.caller_id == caller.graph_id && site.message == 'no_keywords'
      end

      options = graph.method_lookup(options_site)
      no_keywords = graph.method_lookup(no_keywords_site)

      expect(options).to be_complete
      expect(options.targets.map(&:symbol_id)).to eq(['KeywordHost#options'])
      expect(no_keywords).to be_complete
      expect(no_keywords.targets).to eq([])
      expect(no_keywords.rejected_targets).to contain_exactly(
        have_attributes(reason: 'arity_mismatch')
      )
    end
  end

  it 'enforces protected visibility only when the caller and receiver context are known' do
    unrelated = node('Unrelated#run', owner: 'Unrelated', name: 'run')
    descendant = node('Child#run', owner: 'Child', name: 'run')
    unknown = node('Unknown#run', owner: 'Unknown', name: 'run')
    target = node('Base#secret', owner: 'Base', name: 'secret', visibility: :protected)
    infos = [class_info('Unrelated'), class_info('Base'), class_info('Child', superclass: 'Base')]

    unrelated_result = lookup(
      graph_with(nodes: [unrelated, target], class_infos: infos),
      caller: unrelated, message: 'secret', receiver_kind: :instance, receiver_name: 'Base'
    )
    descendant_result = lookup(
      graph_with(nodes: [descendant, target], class_infos: infos),
      caller: descendant, message: 'secret', receiver_kind: :instance, receiver_name: 'Child'
    )
    unknown_result = lookup(
      graph_with(nodes: [unknown, target], class_infos: [class_info('Base')]),
      caller: unknown, message: 'secret', receiver_kind: :instance, receiver_name: 'Base'
    )

    expect(unrelated_result).to be_complete
    expect(unrelated_result.targets).to eq([])
    expect(unrelated_result.rejected_targets).to contain_exactly(
      have_attributes(definition_id: target.graph_id, reason: 'protected_visibility')
    )
    expect(descendant_result).to be_complete
    expect(descendant_result.targets).to eq([target])
    expect(unknown_result).to be_partial
    expect(unknown_result.targets).to eq([target])
    expect(unknown_result.rejected_targets).to eq([])
  end

  it 'uses Object as the implicit superclass for normal dispatch and super' do
    source = <<~RUBY
      class Object
        def fallback = :object
        def render = :object
      end

      class Host
        def run = fallback
        def render = super
      end
    RUBY

    with_project(files: { 'app/object_ancestry.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      run = scan.nodes.find { |node| node.symbol_id == 'Host#run' }
      render = scan.nodes.find { |node| node.symbol_id == 'Host#render' }
      fallback_site = scan.call_sites.find { |site| site.caller_id == run.graph_id && site.message == 'fallback' }
      super_site = scan.call_sites.find { |site| site.caller_id == render.graph_id && site.receiver_kind == :super }
      host_info = scan.class_infos.find { |info| info.id == 'Host' }

      expect(host_info.superclass).to eq('Object')
      expect(graph.method_lookup(fallback_site).targets.map(&:symbol_id)).to eq(['Object#fallback'])
      expect(graph.method_lookup(super_site).targets.map(&:symbol_id)).to eq(['Object#render'])
    end
  end

  it 'does not commit explicit or runtime ancestry mutations as unconditional class metadata' do
    source = <<~RUBY
      module Prefix
        def render = :prefix
      end
      module RuntimeMix
        def render = :mix
      end
      class Host
        prepend Prefix if ENV['USE_PREFIX']
        def render = :host

        def self.activate
          prepend RuntimeMix
        end
      end
      class Activator
        def run
          Host.include RuntimeMix
        end
      end
    RUBY

    with_project(files: { 'app/runtime_ancestry.rb' => source }, config: { cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      host = scan.class_infos.find { |info| info.id == 'Host' }
      activator = scan.class_infos.find { |info| info.id == 'Activator' }
      caller = scan.nodes.find { |node| node.symbol_id == 'Activator#run' }
      result = lookup(graph, caller: caller, message: 'render', receiver_kind: :instance, receiver_name: 'Host')

      expect(host.prepends).to eq([])
      expect(host.includes).to eq([])
      expect(activator.includes).to eq([])
      expect(scan.semantic_blockers.count { |blocker| blocker.kind == :dynamic_ancestry }).to eq(3)
      expect(result).to be_partial
      expect(result.targets.map(&:symbol_id)).to include('Host#render', 'Prefix#render')
      expect(result.rejected_targets).to eq([])
    end
  end
end
