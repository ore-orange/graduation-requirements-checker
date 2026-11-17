# frozen_string_literal: true

# Googleアカウントでのログイン。
# スコープは openid 相当の email と profile だけに絞る。これ以上を求めると
# Google の審査対象になり、未審査アプリの警告画面やテストユーザー登録が必要になる。
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           ENV.fetch('GOOGLE_CLIENT_ID', nil),
           ENV.fetch('GOOGLE_CLIENT_SECRET', nil),
           scope: 'email,profile',
           # 既にGoogleにログイン済みでも毎回アカウントを選ばせる。
           # 大学のアカウントと私用のアカウントを使い分ける人が間違えないようにするため。
           prompt: 'select_account'
end

# コールバックURLはリクエストのHostヘッダーから組み立てられる。偽装されると
# 認可コードを別のホストへ送らせられるため、受け付けるホストを明示する。
OmniAuth.config.allowed_hosts = ENV.fetch('ALLOWED_HOSTS', 'localhost').split(',').map(&:strip)

# OmniAuth 2.x は GET での開始を禁じている（CVE-2015-9284）。
# 画面側も link_to ではなく button_to を使い、CSRFトークンを付けて POST する。
OmniAuth.config.allowed_request_methods = %i[post]

# 失敗時は例外を投げずに自前の画面へ流す。開発環境では既定が raise のため明示する。
OmniAuth.config.on_failure = proc { |env| OauthSessionsController.action(:failure).call(env) }

