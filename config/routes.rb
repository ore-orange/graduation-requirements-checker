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

  resource :session, only: %i[new create destroy]

  # 初回ログイン後にコースと入学年度を登録する。
  resource :student, only: %i[new create]

  # Googleログイン。開始のPOSTはOmniAuthのミドルウェアが先に受けるため、
  # 下のルートはURLを組み立てるためだけに置いている。
  post 'auth/:provider', to: 'oauth_sessions#passthru', as: :oauth_request
  get 'auth/failure', to: 'oauth_sessions#failure'
  get 'auth/:provider/callback', to: 'oauth_sessions#create'

  # 大項目を開いたときだけ小項目を取りに来る（進捗ダッシュボードのドロップダウン）
  get 'dashboard/groups/:id', to: 'dashboard_groups#show', as: :dashboard_group

  get 'requirements', to: 'requirements#show'
  get 'plan', to: 'plans#show'
  get 'profile', to: 'profiles#show'

  resources :plan_courses, only: %i[create destroy], path: 'plan/courses'
  # 指導教員の承認が要る科目に対する、学生自身の「承認あり／なし／未回答」の回答。対象は student_courses か
  # planned_courses のどちらか一方（kind で区別）。
  patch 'approvals', to: 'approvals#update'

  resources :course_registrations, only: :index
  resources :timetable_uploads, only: %i[create show destroy] do
    member do
      post :commit
      patch :update_rows
      get 'page_image/:page', action: :page_image, as: :page_image
    end
  end
end
