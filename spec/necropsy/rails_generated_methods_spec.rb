# frozen_string_literal: true

RSpec.describe 'Rails generated method diagnostics' do
  it 'reports macros instead of generated methods as removal candidates' do
    files = {
      'app/models/user.rb' => <<~RUBY
        class User < ApplicationRecord
          belongs_to :account
          has_many :items
          def ordinary_dead; end
        end
      RUBY
    }
    config = { cache: { enabled: false }, frameworks: ['rails'] }

    with_project(files: files, config: config) do |root|
      report = Necropsy::Runner.new(root: root).analyze
      generated_names = report.graph.method_nodes.select do |node|
        node.defined_via.to_s.start_with?('rails_')
      end.map(&:name)

      expect(report.findings.map { |finding| finding.node.name }).to contain_exactly('ordinary_dead')
      expect(generated_names).to include('build_account', 'create_account!', 'items', 'items=')
      expect(generated_names).not_to include('build_items', 'create_items')
      expect(report.diagnostics.fetch('rails_generated_macros')).to include(
        'count' => 2,
        'generated_method_count' => generated_names.length,
        'macros' => include(
          include('owner' => 'User', 'macro' => 'belongs_to'),
          include('owner' => 'User', 'macro' => 'has_many')
        )
      )
    end
  end
end
