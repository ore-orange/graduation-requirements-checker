# frozen_string_literal: true

class Student < ApplicationRecord
  belongs_to :user
  belongs_to :program
  # 判定に使う便覧。コースの識別名と入学年度で決まるが、探すのではなく学生が持つ。
  belongs_to :curriculum, optional: true
  has_many :student_courses, dependent: :restrict_with_error
  has_many :courses, through: :student_courses
  has_many :planned_courses, dependent: :destroy
  has_many :future_courses, through: :planned_courses, source: :course
  has_many :student_program_assignments, dependent: :restrict_with_error

  # 卒業要件はコース単位で分かれる。学科はコースを通して引く。
  delegate :curriculum_slug, :department, to: :program

  # 便覧は、コースの識別名と入学年度から引く。学生が持つのは引き当てた結果で、以後は探さない。
  before_validation :assign_curriculum, on: :create

  validates :user_id, uniqueness: true
  validates :admission_year, numericality: { only_integer: true, greater_than: 0, less_than: 10_000 }
  # 入れた瞬間に画面が出せない学生を作らないよう、入学年度の便覧があることを確かめる。
  # 作成時だけにするのは、後から便覧を入れ替えても既存の学生を保存できなくしないため。
  validate :curriculum_must_exist, on: :create
  validate :curriculum_must_be_published, if: :will_save_change_to_curriculum_id?

  private

  def assign_curriculum
    return if curriculum || program.blank? || curriculum_slug.blank? || !admission_year.is_a?(Integer)

    self.curriculum = Curriculum.published.find_by(slug: curriculum_slug, admission_year: admission_year)
  end

  # 便覧を用意していないコースは、まだ年度を絞れないので素通しする。
  def curriculum_must_exist
    return if program.blank? || curriculum_slug.blank? || admission_year.blank?
    return unless admission_year.is_a?(Integer)
    return if curriculum

    errors.add(:admission_year, :no_curriculum)
  end

  # 下書きは取り込み途中の作業中の文書。学生の判定に使われてはならない。
  def curriculum_must_be_published
    errors.add(:curriculum, 'は公開済みのものにしてください') if curriculum && !curriculum.published?
  end
end

