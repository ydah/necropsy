# frozen_string_literal: true

RSpec.describe Necropsy::ConventionRules do
  subject(:rules) { described_class.new }

  it 'scopes RuboCop event hooks to a RuboCop ancestor' do
    hit = rules.method_hit(
      owner: 'CustomCop', method_name: 'on_send', ancestors: ['RuboCop::Cop::Base'], frameworks: ['rubocop']
    )

    expect(hit).to include('rule_id' => 'rubocop.event_callback', 'family' => 'ancestor_scoped_hook')
    expect(rules.method_hit(owner: 'Unrelated', method_name: 'on_send', ancestors: [], frameworks: ['rubocop'])).to be_nil
  end

  it 'matches Rails callback symbols only in a scoped owner family' do
    hit = rules.method_hit(
      owner: 'AccountsController', method_name: 'before_action', ancestors: [], frameworks: ['rails']
    )

    expect(hit).to include('rule_id' => 'rails.callback_symbol')
    expect(rules.method_hit(owner: 'Utility', method_name: 'before_action', ancestors: [], frameworks: ['rails'])).to be_nil
  end

  it 'rejects broad unscoped rules' do
    expect do
      described_class::Rule.new(id: 'broad', family: :hook, methods: ['on_send'])
    end.to raise_error(ArgumentError, /unscoped/)
  end

  it 'emits a scoped root for a RuboCop on_* method' do
    source = <<~RUBY
      class ScopedCop < RuboCop::Cop::Base
        def on_send(node)
        end
      end
      class Unrelated
        def on_send(node)
        end
      end
    RUBY

    with_project(files: { 'lib/cop.rb' => source }, config: { frameworks: ['rubocop'], cache: { enabled: false } }) do |root|
      scan = scan_project(root)

      hinted_symbols = scan.entrypoint_hints.filter_map do |hint|
        scan.nodes.find { |node| node.graph_id == hint.node_id }&.symbol_id
      end
      expect(hinted_symbols).to include('ScopedCop#on_send')
      expect(hinted_symbols).not_to include('Unrelated#on_send')
    end
  end
end
