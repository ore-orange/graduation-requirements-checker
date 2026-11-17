# frozen_string_literal: true

require 'json'

namespace :course_master do
  # デモの Course の種(db/course_master.json)を、config/curricula の便覧JSONから作り直す。
  # 便覧は「科目番号から区分が決まらない科目」しか持たなくなっていくが、科目の実体は courses テーブルが正本で、
  # デモの履修はそこにある科目を引く。種を便覧の文書から切り離しておくために、ファイルとして持つ。
  # 年度の便覧を足したときは、このタスクを流し直してコミットする。
  desc '便覧JSON(config/curricula/**/*.json)の科目から db/course_master.json を作り直す'
  task build: :environment do
    entries = Rails.root.glob('config/curricula/**/*.json').sort.flat_map do |path|
      JSON.parse(path.read).fetch('courses', [])
    end

    # (番号, 名前)で1件にまとめる。単位は最初に出た値を採る(DemoData の先着優先と同じ理由:
    # 片方の年度で「未確認」にしている単位を、もう片方の年度の値で復活させない)。
    master = entries.select { |entry| entry['number'].present? }
                    .uniq { |entry| entry.values_at('number', 'name') }
                    .map { |entry| entry.slice('number', 'name', 'credits') }
                    .sort_by { |entry| [entry['number'], entry['name']] }

    File.write(DemoData::COURSE_MASTER_FILE, "#{JSON.pretty_generate(master)}\n")
    puts "wrote #{DemoData::COURSE_MASTER_FILE} (#{master.size} courses)"
  end
end

