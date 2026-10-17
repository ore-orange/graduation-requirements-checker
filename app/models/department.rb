# frozen_string_literal: true

class Department < ApplicationRecord
  belongs_to :faculty
  has_many :programs, dependent: :restrict_with_error
  has_many :students, dependent: :restrict_with_error

  validates :name, presence: true
end

