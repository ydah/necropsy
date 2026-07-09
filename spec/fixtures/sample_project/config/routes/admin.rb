# frozen_string_literal: true

namespace :admin do
  constraints ->(_request) { true } do
    get 'widgets/drawn', to: 'widgets#drawn'
  end
end
