# frozen_string_literal: true

RSpec.describe Necropsy::EntryPoints::Rails do
  describe '#apply' do
    subject(:entrypoints) do
      described_class.new.apply(graph, project_for(project_root))
      graph.entry_points.to_h { |entry| [entry.node_id, entry.reason] }
    end

    let(:graph) { graph_with(nodes: nodes) }

    context 'when Rails is not enabled' do
      let(:project_root) { create_project }
      let(:nodes) { [node('WidgetsController#index', owner: 'WidgetsController', name: 'index')] }

      it { is_expected.to eq({}) }
    end

    context 'when Rails is enabled' do
      let(:project_root) { create_project(files: route_files, config: { frameworks: ['rails'] }) }
      let(:route_files) do
        {
          'config/routes.rb' => <<~RUBY,
            Rails.application.routes.draw do
              concern :auditable do
                get :audit, on: :collection
              end

              root "widgets#index"
              get "legacy" => "widgets#legacy"
              get "widgets/path_shorthand"
              mount MountedEngine, at: "/mounted"
              namespace :admin do
                get "widgets", to: "widgets#index"
              end
              controller :widgets do
                get :contextual
              end
              scope controller: :widgets do
                get :scoped
              end
              resources :widgets, concerns: :auditable
              resource :day
              resource :person
              draw :extra
            end
          RUBY
          'config/routes/extra.rb' => <<~RUBY,
            get "widgets/drawn"
          RUBY
          'app/views/widgets/index.html.erb' => <<~ERB,
            <%= widget_title %>
            <%= admin? %>
            <%= widget.present! %>
            <%# hidden_helper %>
          ERB
          'app/components/title_component.html.erb' => '<!-- hidden_component_helper -->'
        }
      end
      let(:nodes) do
        route_nodes + [
          node('WidgetJob#perform', file: 'app/jobs/widget_job.rb', owner: 'WidgetJob', name: 'perform'),
          node('WidgetMailer#notify', file: 'app/mailers/widget_mailer.rb', owner: 'WidgetMailer', name: 'notify'),
          node(
            'WidgetsHelper#widget_title',
            file: 'app/helpers/widgets_helper.rb',
            owner: 'WidgetsHelper',
            name: 'widget_title'
          ),
          node(
            'WidgetsHelper#hidden_helper',
            file: 'app/helpers/widgets_helper.rb',
            owner: 'WidgetsHelper',
            name: 'hidden_helper'
          ),
          node('WidgetsHelper#admin?', file: 'app/helpers/widgets_helper.rb', owner: 'WidgetsHelper', name: 'admin?'),
          node('Widget#present!', file: 'app/models/widget.rb', owner: 'Widget', name: 'present!'),
          node('Migration#change', file: 'db/migrate/20260721000000_create_widgets.rb', owner: 'Migration', name: 'change'),
          node('PrivateMailer#secret', file: 'app/mailers/private_mailer.rb', owner: 'PrivateMailer', name: 'secret',
                                      visibility: :private),
          node('TitleComponent#call', file: 'app/components/title_component.rb', owner: 'TitleComponent', name: 'call'),
          node(
            'TitleComponent#before_render',
            file: 'app/components/title_component.rb',
            owner: 'TitleComponent',
            name: 'before_render'
          ),
          node('TitleComponent#helper', file: 'app/components/title_component.rb', owner: 'TitleComponent', name: 'helper'),
          node(
            'file:config/initializers/hooks.rb',
            kind: :block_entry,
            file: 'config/initializers/hooks.rb',
            owner: nil,
            name: 'config/initializers/hooks.rb'
          )
        ]
      end

      it 'adds route and framework entry points' do
        expect(entrypoints).to include(
          'WidgetsController#index' => :rails_route,
          'WidgetsController#legacy' => :rails_route,
          'WidgetsController#path_shorthand' => :rails_route,
          'WidgetsController#contextual' => :rails_route,
          'WidgetsController#scoped' => :rails_route,
          'WidgetsController#audit' => :rails_route,
          'WidgetsController#drawn' => :rails_route,
          'Admin::WidgetsController#index' => :rails_route,
          'MountedEngine.call' => :rails_route,
          'WidgetJob#perform' => :job_perform,
          'WidgetMailer#notify' => :mailer_action,
          'WidgetsHelper#widget_title' => :rails_view_helper,
          'WidgetsHelper#admin?' => :rails_view_helper,
          'Widget#present!' => :rails_view_reference,
          'Migration#change' => :rails_migration,
          'DaysController#show' => :rails_route,
          'PeopleController#show' => :rails_route,
          'TitleComponent#call' => :rails_component,
          'TitleComponent#before_render' => :rails_component,
          'file:config/initializers/hooks.rb' => :callback_registered
        )
      end

      it 'does not add helpers or component methods only mentioned in comments' do
        expect(entrypoints).not_to include('WidgetsHelper#hidden_helper', 'TitleComponent#helper', 'PrivateMailer#secret')
      end
    end


    context 'when an unnamespaced route has a namespaced controller with the same suffix' do
      let(:project_root) do
        create_project(
          files: { 'config/routes.rb' => "get 'widgets', to: 'widgets#index'\n" },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [node('Admin::WidgetsController#index', owner: 'Admin::WidgetsController', name: 'index')]
      end

      it 'does not treat the namespaced action as the route target' do
        expect(entrypoints).not_to include('Admin::WidgetsController#index')
      end
    end
  end

  def route_nodes
    %w[index legacy path_shorthand contextual scoped audit drawn].map do |action|
      node("WidgetsController##{action}", owner: 'WidgetsController', name: action)
    end + [
      node('Admin::WidgetsController#index', owner: 'Admin::WidgetsController', name: 'index'),
      node('DaysController#show', owner: 'DaysController', name: 'show'),
      node('PeopleController#show', owner: 'PeopleController', name: 'show'),
      node('MountedEngine.call', kind: :singleton_method, owner: 'MountedEngine', name: 'call')
    ]
  end
end
