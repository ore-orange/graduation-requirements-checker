# frozen_string_literal: true

class DemoAccount
  class Unavailable < StandardError; end

  # デモ学生1人分の定義(実在の Student モデルの行ではない)。email は入学年度ごとに固有
  # (同じメールで入学年度違いの学生を2つ作ることはできない)。
  Definition = Data.define(:email, :admission_year, :department) do
    # この学生が判定に使う、公開済みの便覧。便覧をまだ取り込んでいない入学年度は nil になる。
    def curriculum
      Curriculum.published.find_by(slug: department, admission_year: admission_year)
    end
  end

  DEPARTMENT = 'intelligent_informatics'

  # 既存の呼び口(demo_data.rb や student_workspace.rb)を壊さないよう、1人目は元のメールのまま。
  STUDENTS = [
    Definition.new(email: 'demo@graduation-checker.example.test', admission_year: 2024, department: DEPARTMENT),
    Definition.new(email: 'demo-2025@graduation-checker.example.test', admission_year: 2025, department: DEPARTMENT)
  ].freeze

  def self.students
    STUDENTS
  end

  # ナビの切り替え候補や、切り替え時の「知っている年度か」の判定に使う。STUDENTS の定義ではなく、
  # 実際にDBへ投入済みのデモ学生だけに絞る。便覧がまだ未公開(取り込み待ち)の年度の定義が STUDENTS に
  # あっても、実在しないなら画面には出さない・切り替えでも選ばせない(さもないと選んだ瞬間に
  # 「デモデータが未設定です」で全画面がロックアウトしてしまう)。
  def self.available_students
    STUDENTS.select { |definition| find_student(definition) }
  end

  # PUBLIC_DEMO=1 は、認証が入るまでの仮公開用。ローカル限定の制限を外し、固定のデモ学生を誰にでも見せる。
  # 実際の成績データを入れた環境では設定しない。
  def self.public_demo?
    ENV['PUBLIC_DEMO'] == '1'
  end

  def self.enabled?
    Rails.env.local? || public_demo?
  end

  # アプリ全体が今も参照する「唯一のデモ学生」。呼び口を壊さないよう、常に1人目(2024年度入学)を返す。
  def self.student
    student_for(STUDENTS.first)
  end

  # 画面の切り替え用。STUDENTS に無い年度(壊れたセッションの値など)は、常に正しい student にそのまま落ちる
  # ("安全側"の既定)ので、呼び手は年度の妥当性を自分で確かめなくてよい。
  def self.student_for_year(admission_year)
    definition = STUDENTS.find { |candidate| candidate.admission_year == admission_year }
    definition ? student_for(definition) : student
  end

  # definition から実際の Student を引く。既存の呼び口(.student)を壊さないよう、ここが唯一の実装。
  def self.student_for(definition)
    raise Unavailable, 'ローカルデモは開発・テスト環境でのみ利用できます。' unless enabled?

    student = find_student(definition)
    return student if student

    raise Unavailable, 'デモデータが未設定です。開発環境で bin/rails db:seed を実行してください。'
  end

  # definition に対応する Student が実在すれば返す。無ければ nil(例外にしない。available_students が
  # 「実在するか」だけを静かに確かめたいので、ここでは enabled? も見ない)。
  def self.find_student(definition)
    student = User.find_by(email: definition.email)&.student
    student if student&.admission_year == definition.admission_year
  end
  private_class_method :find_student
end

