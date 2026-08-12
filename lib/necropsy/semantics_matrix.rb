# frozen_string_literal: true

require 'json'
require 'prism'
require 'yaml'

module Necropsy
  class SemanticsMatrix
    SCHEMA_VERSION = 'necropsy.semantics.v1'
    STATUSES = %w[exact partial blocked unsupported].freeze

    EXACT_PRISM_NODES = %i[
      AliasMethodNode ArgumentsNode ArrayNode AssocNode BeginNode BlockArgumentNode BlockLocalVariableNode
      BlockParameterNode BlockParametersNode ClassNode ConstantPathNode ConstantReadNode ConstantTargetNode
      DefNode FalseNode FloatNode ForwardingArgumentsNode ForwardingParameterNode HashNode ImaginaryNode
      ImplicitNode ImplicitRestNode IntegerNode ItLocalVariableReadNode ItParametersNode KeywordHashNode
      KeywordRestParameterNode LocalVariableReadNode LocalVariableTargetNode ModuleNode NilNode
      NoKeywordsParameterNode NumberedParametersNode NumberedReferenceReadNode OptionalKeywordParameterNode
      OptionalParameterNode ParametersNode ParenthesesNode RationalNode RegularExpressionNode
      RequiredKeywordParameterNode RequiredParameterNode RestParameterNode SelfNode SourceEncodingNode
      SourceFileNode SourceLineNode StatementsNode StringNode SymbolNode TrueNode
    ].to_set.freeze

    PARTIAL_PRISM_NODES = %i[
      AliasGlobalVariableNode AlternationPatternNode AndNode ArrayPatternNode AssocSplatNode
      BackReferenceReadNode BlockNode BreakNode CallAndWriteNode CallNode CallOperatorWriteNode CallOrWriteNode
      CallTargetNode CapturePatternNode CaseMatchNode CaseNode ClassVariableAndWriteNode
      ClassVariableOperatorWriteNode ClassVariableOrWriteNode ClassVariableReadNode ClassVariableTargetNode
      ClassVariableWriteNode ConstantAndWriteNode ConstantOperatorWriteNode ConstantOrWriteNode
      ConstantPathAndWriteNode ConstantPathOperatorWriteNode ConstantPathOrWriteNode ConstantPathTargetNode
      ConstantPathWriteNode ConstantWriteNode DefinedNode ElseNode EmbeddedStatementsNode EmbeddedVariableNode
      EnsureNode FindPatternNode FlipFlopNode ForNode ForwardingSuperNode GlobalVariableAndWriteNode
      GlobalVariableOperatorWriteNode GlobalVariableOrWriteNode GlobalVariableReadNode GlobalVariableTargetNode
      GlobalVariableWriteNode HashPatternNode IfNode InNode IndexAndWriteNode IndexOperatorWriteNode IndexOrWriteNode
      IndexTargetNode InstanceVariableAndWriteNode InstanceVariableOperatorWriteNode InstanceVariableOrWriteNode
      InstanceVariableReadNode InstanceVariableTargetNode InstanceVariableWriteNode InterpolatedMatchLastLineNode
      InterpolatedRegularExpressionNode InterpolatedStringNode InterpolatedSymbolNode InterpolatedXStringNode
      LambdaNode LocalVariableAndWriteNode LocalVariableOperatorWriteNode LocalVariableOrWriteNode
      LocalVariableWriteNode MatchLastLineNode MatchPredicateNode MatchRequiredNode MatchWriteNode MultiTargetNode
      MultiWriteNode NextNode OrNode PinnedExpressionNode PinnedVariableNode PostExecutionNode PreExecutionNode
      ProgramNode RangeNode RedoNode RescueModifierNode RescueNode RetryNode ReturnNode ShareableConstantNode
      SingletonClassNode SplatNode SuperNode UndefNode UnlessNode UntilNode WhenNode WhileNode XStringNode YieldNode
    ].to_set.freeze

    BLOCKED_PRISM_NODES = %i[MissingNode].to_set.freeze

    RUBY_HOOK_STATUS = {
      'inherited' => 'partial',
      'included' => 'partial',
      'extended' => 'partial',
      'prepended' => 'partial',
      'method_added' => 'partial',
      'singleton_method_added' => 'partial',
      'const_missing' => 'partial',
      'method_missing' => 'partial',
      'respond_to_missing?' => 'partial'
    }.freeze

    def to_h
      {
        'schema_version' => SCHEMA_VERSION,
        'runtime' => { 'ruby' => RUBY_VERSION, 'prism' => Prism::VERSION },
        'statuses' => STATUSES,
        'prism_nodes' => prism_nodes,
        'ruby_hooks' => ruby_hooks,
        'rails_dsl' => rails_dsl
      }
    end

    def render(format: :human)
      case format.to_sym
      when :json then JSON.pretty_generate(to_h)
      when :yaml then YAML.dump(to_h)
      when :human then render_human
      else raise Error, "semantics supports human, json, or yaml output (got #{format})"
      end
    end

    private

    def prism_nodes
      prism_node_classes.map do |name|
        status = prism_status(name)
        { 'name' => name.to_s, 'status' => status, 'reason' => prism_reason(status) }
      end
    end

    def prism_node_classes
      Prism.constants.filter_map do |name|
        value = Prism.const_get(name)
        name if value.is_a?(Class) && value < Prism::Node
      end.sort_by(&:to_s)
    end

    def prism_status(name)
      return 'exact' if EXACT_PRISM_NODES.include?(name)
      return 'partial' if PARTIAL_PRISM_NODES.include?(name)
      return 'blocked' if BLOCKED_PRISM_NODES.include?(name)

      'unsupported'
    end

    def prism_reason(status)
      case status
      when 'exact' then 'scanner preserves the node structure without narrowing dispatch unsafely'
      when 'partial' then 'calls are traversed conservatively but full Ruby runtime semantics are not claimed'
      when 'blocked' then 'analysis health or a semantic blocker prevents an actionable conclusion'
      else 'no reviewed scanner semantics are registered for this Prism node version'
      end
    end

    def ruby_hooks
      Confidence::Scorer::RUBY_HOOKS.sort.map do |name|
        {
          'name' => name,
          'status' => RUBY_HOOK_STATUS.fetch(name, 'unsupported'),
          'reason' => 'recognized as an implicit VM callback; confidence is lowered without claiming a runtime root'
        }
      end
    end

    def rails_dsl
      entries = {}
      AstScanner::RAILS_CALLBACK_MACROS.each { |name| entries[name.to_s] = dsl_entry(name, 'callback') }
      AstScanner::RAILS_GENERATED_METHOD_MACROS.each do |name|
        entries[name.to_s] = dsl_entry(name, 'generated_method')
      end
      EntryPoints::Rails::ROUTE_DSL_CALLS.each { |name| entries[name.to_s] = dsl_entry(name, 'route') }
      entries.keys.sort.map { |name| entries.fetch(name) }
    end

    def dsl_entry(name, family)
      reasons = {
        'callback' => 'literal callback methods and conditions are rooted; dynamic registration is blocked',
        'generated_method' => 'literal APIs are grouped by macro source; version-dependent surfaces remain conservative',
        'route' => 'Prism verifies route DSL calls and literal targets; dynamic targets create scoped blockers'
      }
      { 'name' => name.to_s, 'family' => family, 'status' => 'partial', 'reason' => reasons.fetch(family) }
    end

    def render_human
      data = to_h
      counts = data.fetch('prism_nodes').tally { |entry| entry.fetch('status') }
      [
        "Semantics matrix #{SCHEMA_VERSION}",
        "Ruby #{RUBY_VERSION}; Prism #{Prism::VERSION}",
        "Prism nodes: #{STATUSES.map { |status| "#{status}=#{counts.fetch(status, 0)}" }.join(', ')}",
        "Ruby hooks: #{data.fetch('ruby_hooks').length}",
        "Rails DSL entries: #{data.fetch('rails_dsl').length}"
      ].join("\n")
    end
  end
end
