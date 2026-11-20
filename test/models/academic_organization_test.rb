# frozen_string_literal: true

require 'test_helper'
# 学部・学科のマスタはseedの一部で、オートロードの対象外なので直接読む
require Rails.root.join('db/seeds/academic_organizations')

class AcademicOrganizationTest < ActiveSupport::TestCase
  test '同じ名前の学部は作れない' do
    Faculty.create!(name: 'テスト学部A')
    assert_raises(ActiveRecord::RecordInvalid) { Faculty.create!(name: 'テスト学部A') }
  end

  test '同じ学部に同じ名前の学科は作れないが、別の学部なら作れる' do
    first = Faculty.create!(name: 'テスト学部B')
    second = Faculty.create!(name: 'テスト学部C')
    first.departments.create!(name: 'テスト学科')
    assert_raises(ActiveRecord::RecordInvalid) { first.departments.create!(name: 'テスト学科') }
    assert second.departments.create!(name: 'テスト学科').persisted?
  end

  test 'マスタは2回流しても増えない' do
    AcademicOrganizations.load!
    faculties = Faculty.count
    departments = Department.count
    AcademicOrganizations.load!
    assert_equal faculties, Faculty.count
    assert_equal departments, Department.count
  end

  test 'マスタに工学部 工学科がある' do
    AcademicOrganizations.load!
    assert Department.joins(:faculty).exists?(name: '工学科', faculty: { name: '工学部' })
  end
end

