Rails.application.routes.draw do
  root "dashboard#show"

  resources :checkouts, only: :create
  resources :crashes, only: :create
  resource :recovery, only: :create
  resource :reset, only: :create

  get "up" => "rails/health#show", as: :rails_health_check
end
