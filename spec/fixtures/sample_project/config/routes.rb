# frozen_string_literal: true

Rails.application.routes.draw do
  concern :auditable do
    get :audit
  end

  root 'widgets#index'
  get 'legacy' => 'widgets#legacy'
  mount Sample::MountedEngine, at: '/mounted'

  controller :widgets do
    get :contextual
  end

  scope controller: :widgets do
    get :scoped
  end

  resources :widgets, concerns: :auditable

  draw :admin

  namespace :admin do
    resources :widgets, only: [:index] do
      member do
        get :preview
      end
    end
  end
end
