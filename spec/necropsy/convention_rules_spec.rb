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

  it 'rejects excess rules instead of silently truncating them' do
    repeated = Array.new(described_class::MAX_RULES + 1) do |index|
      described_class::Rule.new(id: "rule.#{index}", family: :hook, methods: ['call'], owner_patterns: ['Owner'])
    end

    expect { described_class.new(rules: repeated) }.to raise_error(ArgumentError, /too many convention rules/)
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

  it 'enables framework rules from a safely inventoried dependency artifact' do
    source = <<~RUBY
      class ScopedCop < RuboCop::Cop::Base
        def on_send(node)
        end
      end
    RUBY

    with_project(
      files: { 'Gemfile.lock' => "    rubocop (1.80.0)\n", 'lib/cop.rb' => source },
      config: { cache: { enabled: false } }
    ) do |root|
      scan = scan_project(root)
      hinted_symbols = scan.entrypoint_hints.filter_map do |hint|
        scan.nodes.find { |node| node.graph_id == hint.node_id }&.symbol_id
      end

      expect(hinted_symbols).to include('ScopedCop#on_send')
    end
  end

  it 'evaluates non-on method names for matching framework families' do
    source = <<~RUBY
      class AccountsController < ApplicationController
        def before_action
        end
      end
    RUBY

    with_project(files: { 'app/controllers/accounts_controller.rb' => source },
                 config: { frameworks: ['rails'], cache: { enabled: false } }) do |root|
      scan = scan_project(root)
      hinted_symbols = scan.entrypoint_hints.filter_map do |hint|
        scan.nodes.find { |node| node.graph_id == hint.node_id }&.symbol_id
      end

      expect(hinted_symbols).to include('AccountsController#before_action')
    end
  end
end
