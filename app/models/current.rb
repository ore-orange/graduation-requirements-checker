# frozen_string_literal: true

# リクエストの間だけ「いま誰が見ているか」を持つ。リクエストごとに捨てられる。
class Current < ActiveSupport::CurrentAttributes
  attribute :session

  delegate :user, to: :session, allow_nil: true
end

