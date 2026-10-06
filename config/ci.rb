# Run using bin/ci

CI.run do
  step 'Style: Ruby', 'bin/rubocop'
  step 'Style: YAML', 'bundle exec yamlfmt config/locales'

  step 'Security: Gem audit', 'bin/bundler-audit'
  step 'Security: Importmap vulnerability audit', 'bin/importmap audit'
  step 'Security: Brakeman code analysis',
       'bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error'

  step 'Tests: Rails', 'bin/rails test'

  # system test はローカルに Chrome が無いため既定では実行しない（CI では実行される）
  # step "Tests: System", "bin/rails test:system"
end
