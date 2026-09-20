Rails.application.routes.draw do
  resource :session, only: %i[ new create destroy ]
  resources :passwords, param: :token, only: %i[ new create edit update ]

  root "dashboard#index"
  resource :performance, only: :show
  resource :performance_methodology, only: :show, path: "performance/methodology"
  resource :settings, only: %i[show update], controller: :settings
  resource :money_visibility, only: :update
  get "market-data/health", to: "market_data_health#show", as: :market_data_health
  namespace :backups do
    resource :creation, only: :create
    resources :verifications, only: :create
  end
  resource :trade_export, only: :show
  namespace :market_data, path: "market-data" do
    resources :recoveries, only: %i[create destroy]
  end
  resources :positions, only: :index
  resource :current_market_price_refresh, only: :create
  resources :transactions, only: :index
  resources :institutions
  resources :instruments do
    resources :trades, only: %i[ new create ]
    resources :corporate_actions, only: %i[ new create ]
    get "quantity-actions/new", to: "corporate_actions#new_quantity", as: :new_quantity_action
    post "quantity-actions", to: "corporate_actions#create_quantity", as: :quantity_actions
  end
  resources :trades, except: %i[ index show ]
  resources :corporate_actions, except: %i[index show]
  get "quantity-actions/new", to: "corporate_actions#new_quantity", as: :new_quantity_action
  post "quantity-actions", to: "corporate_actions#create_quantity", as: :quantity_actions
  get "quantity-actions/:id/edit", to: "corporate_actions#edit_quantity", as: :edit_quantity_action
  patch "quantity-actions/:id", to: "corporate_actions#update_quantity", as: :quantity_action

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
