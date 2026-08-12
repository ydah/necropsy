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
                get "widgets",
                    to: "widgets#index"
              end
              scope module: :v2 do get "widgets", to: "widgets#index" end
              scope({ module: :v3 }) { get "widgets", to: "widgets#index" }
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
          node('Migration#change', file: 'db/migrate/20260721000000_create_widgets.rb', owner: 'Migration',
                                   name: 'change'),
          node('PrivateMailer#secret', file: 'app/mailers/private_mailer.rb', owner: 'PrivateMailer', name: 'secret',
                                       visibility: :private),
          node('TitleComponent#call', file: 'app/components/title_component.rb', owner: 'TitleComponent', name: 'call'),
          node(
            'TitleComponent#before_render',
            file: 'app/components/title_component.rb',
            owner: 'TitleComponent',
            name: 'before_render'
          ),
          node('TitleComponent#helper', file: 'app/components/title_component.rb', owner: 'TitleComponent',
                                        name: 'helper'),
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
          'V2::WidgetsController#index' => :rails_route,
          'V3::WidgetsController#index' => :rails_route,
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
        expect(entrypoints).not_to include('WidgetsHelper#hidden_helper', 'TitleComponent#helper',
                                           'PrivateMailer#secret')
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

    context 'with static custom inflections' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' => "resource :criterion\nnamespace :api do\n  get 'widgets', to: 'widgets#index'\nend\n",
            'config/initializers/inflections.rb' => <<~RUBY
              ActiveSupport::Inflector.inflections do |inflect|
                inflect.irregular 'criterion', 'criteria'
                inflect.acronym 'API'
              end
            RUBY
          },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [
          node('CriteriaController#show', owner: 'CriteriaController', name: 'show'),
          node('API::WidgetsController#index', owner: 'API::WidgetsController', name: 'index')
        ]
      end

      it 'uses only literal irregular and acronym declarations' do
        expect(entrypoints).to include(
          'CriteriaController#show' => :rails_route,
          'API::WidgetsController#index' => :rails_route
        )
      end
    end

    context 'with adversarial and unsupported custom inflections' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' => "resource :mouse\nresource :equipment\n",
            'config/initializers/inflections.rb' => <<~RUBY
              logger.irregular 'mouse', 'decoys'
              ActiveSupport::Inflector.inflections do |inflect|
                inflect.uncountable %w[equipment]
                inflect.plural(/mouse/, 'rodents')
              end
            RUBY
          },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [
          node('MiceController#show', owner: 'MiceController', name: 'show'),
          node('EquipmentController#show', owner: 'EquipmentController', name: 'show'),
          node('DecoysController#show', owner: 'DecoysController', name: 'show'),
          node('RodentsController#show', owner: 'RodentsController', name: 'show')
        ]
      end

      it 'ignores unrelated calls and blocks pruning when a plural rule cannot be evaluated' do
        expect(entrypoints).to include(
          'MiceController#show' => :rails_route,
          'EquipmentController#show' => :rails_route
        )
        expect(entrypoints).not_to include('DecoysController#show')
        expect(graph.blockers).to include(
          have_attributes(kind: :rails_route_health, scope_kind: :global, scope_value: '*')
        )
        expect(graph.matching_blockers('RodentsController#show').map(&:kind)).to include(:rails_route_health)
      end
    end

    context 'when ordinary Ruby strings resemble route declarations' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' => <<~RUBY
              Rails.application.routes.draw do
                logger.info(%q[get fake, to: "widgets#index"])
              end
            RUBY
          },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) { [node('WidgetsController#index', owner: 'WidgetsController', name: 'index')] }

      it 'does not treat data inside unrelated calls as a route' do
        expect(entrypoints).not_to include('WidgetsController#index')
      end
    end

    context 'when HTML text resembles a helper name' do
      let(:project_root) do
        create_project(
          files: { 'app/views/widgets/index.html.erb' => '<p>display_marker</p><%= actual_helper %>' },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [
          node('WidgetsHelper#display_marker', file: 'app/helpers/widgets_helper.rb',
                                               owner: 'WidgetsHelper', name: 'display_marker'),
          node('WidgetsHelper#actual_helper', file: 'app/helpers/widgets_helper.rb',
                                              owner: 'WidgetsHelper', name: 'actual_helper')
        ]
      end

      it 'roots only calls from executable ERB regions' do
        expect(entrypoints).to include('WidgetsHelper#actual_helper' => :rails_view_helper)
        expect(entrypoints).not_to include('WidgetsHelper#display_marker')
      end
    end

    context 'when route and view files are outside the reference scope' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' => "get 'widgets', to: 'widgets#index'\n",
            'app/views/widgets/index.html.erb' => '<%= widget_title %>'
          },
          config: { frameworks: ['rails'], paths: { reference: ['lib/**'] } }
        )
      end
      let(:nodes) do
        [
          node('WidgetsController#index', owner: 'WidgetsController', name: 'index'),
          node(
            'WidgetsHelper#widget_title',
            file: 'app/helpers/widgets_helper.rb',
            owner: 'WidgetsHelper',
            name: 'widget_title'
          )
        ]
      end

      it 'does not derive entry points from excluded references' do
        expect(entrypoints).not_to include('WidgetsController#index', 'WidgetsHelper#widget_title')
      end
    end

    context 'when a route argument is dynamic' do
      let(:project_root) do
        create_project(
          files: { 'config/routes.rb' => "get route_path, to: target_action\n" },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [node('WidgetsController#index', owner: 'WidgetsController', name: 'index')]
      end

      it 'records a scoped route blocker without inventing a controller root' do
        expect(entrypoints).to eq({})
        expect(graph.blockers.map(&:kind)).to include(:rails_route_dynamic)
      end
    end

    context 'when a dynamic route is inside a known controller scope' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' => 'get route_path, controller: "admin/widgets", action: dynamic_action'
          },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [
          node('Admin::WidgetsController#index', owner: 'Admin::WidgetsController', name: 'index'),
          node('PublicController#index', owner: 'PublicController', name: 'index')
        ]
      end
      let(:graph) do
        graph_with(
          nodes: nodes,
          class_infos: [class_info('Admin::WidgetsController'), class_info('PublicController')]
        )
      end

      it 'blocks the controller surface rather than the routes file' do
        entrypoints
        blocker = graph.blockers.find { |candidate| candidate.kind == :rails_route_dynamic }

        expect(blocker).to have_attributes(
          scope_kind: :owner,
          scope_value: 'Admin::WidgetsController'
        )
        expect(graph.matching_blockers('Admin::WidgetsController#index')).to include(blocker)
        expect(graph.matching_blockers('PublicController#index')).not_to include(blocker)
      end
    end

    context 'when a mounted engine has a static constant target' do
      let(:project_root) do
        create_project(
          files: { 'config/routes.rb' => "mount Admin::Engine, at: '/admin'\n" },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) { [node('Admin::Engine.call', owner: 'Admin::Engine', name: 'call', kind: :singleton_method)] }

      it 'roots the engine without adding a dynamic route blocker' do
        expect(entrypoints).to include('Admin::Engine.call' => :rails_route)
        expect(graph.blockers.map(&:kind)).not_to include(:rails_route_dynamic)
      end
    end

    context 'when dynamic route options resemble literal identifiers' do
      let(:project_root) do
        create_project(
          files: {
            'config/routes.rb' =>
              'get route_path, controller: controller_name, action: action_name'
          },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [node('ControllerNameController#action_name', owner: 'ControllerNameController', name: 'action_name')]
      end

      it 'keeps the blocker global and does not invent a route target' do
        expect(entrypoints).to eq({})
        blocker = graph.blockers.find { |candidate| candidate.kind == :rails_route_dynamic }

        expect(blocker).to have_attributes(scope_kind: :global, scope_value: '*')
      end
    end

    context 'when a routed action is private' do
      let(:project_root) do
        create_project(
          files: { 'config/routes.rb' => "get 'widgets', to: 'widgets#secret'\n" },
          config: { frameworks: ['rails'] }
        )
      end
      let(:nodes) do
        [node('WidgetsController#secret', owner: 'WidgetsController', name: 'secret', visibility: :private)]
      end

      it 'does not root a non-public action' do
        expect(entrypoints).to eq({})
      end
    end

    it 'does not read route or view symlinks that resolve outside the repository' do
      Dir.mktmpdir do |outside|
        outside_route = File.join(outside, 'routes.rb')
        outside_view = File.join(outside, 'index.html.erb')
        File.write(outside_route, "get 'widgets', to: 'widgets#index'\n")
        File.write(outside_view, '<%= widget_title %>')
        root = create_project(config: { frameworks: ['rails'] })
        FileUtils.mkdir_p(File.join(root, 'config'))
        FileUtils.mkdir_p(File.join(root, 'app/views/widgets'))
        File.symlink(outside_route, File.join(root, 'config/routes.rb'))
        File.symlink(outside_view, File.join(root, 'app/views/widgets/index.html.erb'))
        scoped_graph = graph_with(nodes: [
                                    node('WidgetsController#index', owner: 'WidgetsController', name: 'index'),
                                    node(
                                      'WidgetsHelper#widget_title',
                                      file: 'app/helpers/widgets_helper.rb',
                                      owner: 'WidgetsHelper',
                                      name: 'widget_title'
                                    )
                                  ])

        described_class.new.apply(scoped_graph, project_for(root))

        ids = scoped_graph.entry_points.map(&:node_id)
        expect(ids).not_to include('WidgetsController#index', 'WidgetsHelper#widget_title')
      end
    end
  end

  def route_nodes
    %w[index legacy path_shorthand contextual scoped audit drawn].map do |action|
      node("WidgetsController##{action}", owner: 'WidgetsController', name: action)
    end + [
      node('Admin::WidgetsController#index', owner: 'Admin::WidgetsController', name: 'index'),
      node('V2::WidgetsController#index', owner: 'V2::WidgetsController', name: 'index'),
      node('V3::WidgetsController#index', owner: 'V3::WidgetsController', name: 'index'),
      node('DaysController#show', owner: 'DaysController', name: 'show'),
      node('PeopleController#show', owner: 'PeopleController', name: 'show'),
      node('MountedEngine.call', kind: :singleton_method, owner: 'MountedEngine', name: 'call')
    ]
  end
end
