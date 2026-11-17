# frozen_string_literal: true

require 'test_helper'

class GoogleIdentityTest < ActiveSupport::TestCase
  test '確認済みの学内アドレスだけを通す' do
    assert identity(email: 'student@ie.u-ryukyu.ac.jp').allowed_domain?
    assert_not identity(email: 'someone@gmail.com').allowed_domain?
    assert_not identity(email: 'student@ie.u-ryukyu.ac.jp', email_verified: false).allowed_domain?
  end

  # 似せたドメインを部分一致で通さないことの確認。
  test 'ドメインの末尾が一致するだけでは通さない' do
    assert_not identity(email: 'student@evil-ie.u-ryukyu.ac.jp').allowed_domain?
    assert_not identity(email: 'student@ie.u-ryukyu.ac.jp.example.com').allowed_domain?
  end

  test '大文字や前後の空白があっても同じものとして扱う' do
    assert identity(email: '  Student@IE.U-Ryukyu.AC.JP  ').allowed_domain?
  end

  # Googleはこの値を文字列で返すことがある。
  test '確認済みかどうかは文字列のtrueでも読み取る' do
    assert identity(email_verified: 'true').email_verified?
    assert_not identity(email_verified: 'false').email_verified?
    assert_not identity(email_verified: nil).email_verified?
  end

  test '許可するドメインはENVで差し替えられる' do
    with_allowed_domains('example.ac.jp, other.ac.jp') do
      assert identity(email: 'student@other.ac.jp').allowed_domain?
      assert_not identity(email: 'student@ie.u-ryukyu.ac.jp').allowed_domain?
    end
  end

  test 'ENVが空なら既定のドメインに戻す' do
    with_allowed_domains('') do
      assert_equal GoogleIdentity::DEFAULT_DOMAINS, GoogleIdentity.allowed_domains
    end
  end

  private

  def identity(uid: '1', email: 'student@ie.u-ryukyu.ac.jp', email_verified: true)
    GoogleIdentity.new(uid: uid, email: email, email_verified: email_verified)
  end

  def with_allowed_domains(value)
    original = ENV.fetch('ALLOWED_EMAIL_DOMAINS', nil)
    ENV['ALLOWED_EMAIL_DOMAINS'] = value
    yield
  ensure
    ENV['ALLOWED_EMAIL_DOMAINS'] = original
  end
end

