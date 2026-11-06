# frozen_string_literal: true

require 'test_helper'

class UserTest < ActiveSupport::TestCase
  PASSWORD = 'a-test-password'

  setup do
    @user = User.create!(email: 'student@example.test', password: PASSWORD)
  end

  test 'パスワードは平文で持たない' do
    assert_not_equal PASSWORD, @user.password_digest
    assert @user.authenticate(PASSWORD)
    assert_not @user.authenticate('wrong')
  end

  test 'パスワードなしでは作れない' do
    assert_not User.new(email: 'no-password@example.test').valid?
  end

  test 'authenticate_by はメールアドレスとパスワードが揃ったときだけ返す' do
    assert_equal @user, User.authenticate_by(email: @user.email, password: PASSWORD)
    assert_nil User.authenticate_by(email: @user.email, password: 'wrong')
    assert_nil User.authenticate_by(email: 'nobody@example.test', password: PASSWORD)
    assert_nil User.authenticate_by(email: @user.email, password: '')
  end

  test 'ユーザーを消すとセッションも消える' do
    @user.sessions.create!

    assert_difference 'Session.count', -1 do
      @user.destroy!
    end
  end
end

