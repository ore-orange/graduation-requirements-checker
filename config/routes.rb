Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # ルートは進捗ダッシュボード
  root 'dashboard#show'

  # 大項目を開いたときだけ小項目を取りに来る（進捗ダッシュボードのドロップダウン）
  get 'dashboard/groups/:id', to: 'dashboard_groups#show', as: :dashboard_group

  get 'requirements', to: 'requirements#show'
  get 'plan', to: 'plans#show'
  get 'profile', to: 'profiles#show'

  resources :plan_courses, only: %i[create destroy], path: 'plan/courses'
end
