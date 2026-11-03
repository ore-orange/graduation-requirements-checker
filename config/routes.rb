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
  # 指導教員の承認が要る科目に対する、学生自身の「承認あり／なし／未回答」の回答。対象は student_courses か
  # planned_courses のどちらか一方（kind で区別）。
  patch 'approvals', to: 'approvals#update'

  # デモ学生の画面切り替え(開発・テスト環境限定)。年度違いの2人目を画面で確かめるためだけのもの。
  # admission_year はクエリパラメータ(demo_switch_path(admission_year: 2025))。
  # demo_switch_path を引数無しで呼べる必要がある(ナビに切り替えを出さないときのテストが使う)ため、
  # 動的セグメントにはしない。
  patch 'demo_switch', to: 'demo_switch#update', as: :demo_switch

  resources :course_registrations, only: :index
  # 便覧PDFのアップロードと下書きの確認。確認画面は「卒業要件の確認」タブの中にいる扱い。
  # publish は下書きの公開、duplicate は公開済みを複製して直すための下書きを作る。update_rules は要件表の確認画面の保存、update_courses・edit_course は科目表の確認画面の保存と編集欄。
  resources :curricula, only: %i[create show update destroy] do
    member do
      post :publish
      post :duplicate
      post 'pages/:page/read', action: :read_page, as: :read_page
      patch :update_courses
      patch 'courses/bulk_confirm', action: :bulk_confirm_courses, as: :bulk_confirm_courses
      get :edit_course
      patch :update_rules
      get 'page_image/:page', action: :page_image, as: :page_image
    end
  end

  # 保存できなかった要件表の画面は、保存の宛先(update_rules)の URL に出る。そこを開き直した(GET)ときは、確認画面へ戻す。
  get 'curricula/:id/update_rules', to: redirect('/curricula/%{id}#requirements_review')

  resources :timetable_uploads, only: %i[create show destroy] do
    member do
      post :commit
      patch :update_rows
      get 'page_image/:page', action: :page_image, as: :page_image
    end
  end
end
