# frozen_string_literal: true

require 'test_helper'

class StudentsTest < ActionDispatch::IntegrationTest
  setup do
    host! 'localhost'
    @user = User.create!(email: 'new@ie.u-ryukyu.ac.jp', google_uid: 'uid-1')
    faculty = Faculty.create!(name: '登録テスト学部')
    department = faculty.departments.create!(name: '登録テスト学科')
    @program = department.programs.create!(name: '登録テストコース', curriculum_slug: 'intelligent_informatics')
    # カリキュラムを用意していないコース。選択肢に出してはいけない。
    @without_curriculum = department.programs.create!(name: 'カリキュラム未登録コース')
    sign_in_as(@user)
  end

  test '学籍情報が無い人は、どの画面を開いても登録画面へ送られる' do
    get root_path

    assert_redirected_to new_student_path
  end

  test '登録画面にはカリキュラムのあるコースだけが出る' do
    get new_student_path

    assert_response :success
    assert_select 'option[value=?]', @program.id.to_s, count: 1
    assert_select 'option[value=?]', @without_curriculum.id.to_s, count: 0
    # 年度はコースごとに分けて出し、用意のある年度だけを並べる
    assert_select 'optgroup[label=?] option[value=?]', @program.full_name, '2024'
  end

  test 'コースと入学年度を登録すると本来の画面へ進める' do
    assert_difference 'Student.count', 1 do
      post student_path, params: { student: { program_id: @program.id, admission_year: 2024 } }
    end

    assert_redirected_to root_path
    assert_equal @program, @user.reload.student.program
  end

  test 'カリキュラムの無い年度は登録できない' do
    assert_no_difference 'Student.count' do
      post student_path, params: { student: { program_id: @program.id, admission_year: 1999 } }
    end

    assert_response :unprocessable_content
    assert_select 'li', text: /入学年度/
  end

  test '登録済みの人は登録画面へ戻らない' do
    @user.create_student!(program: @program, admission_year: 2024)

    get new_student_path

    assert_redirected_to root_path
  end

  test '未ログインでは登録画面を開けない' do
    sign_out

    get new_student_path

    assert_redirected_to new_session_path
  end
end

