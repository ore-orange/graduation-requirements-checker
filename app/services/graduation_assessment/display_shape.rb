# frozen_string_literal: true

class GraduationAssessment
  # display(画面に出す章・行・小計)の形の検査。Catalogue が便覧を読み込むときに通す。
  #
  # display は画面に出る数字と行の元。欄の綴り違いや null は、黙って別の数字や「必要単位なしの行」になり、
  # 満たしていない要件を画面から消してしまう。空欄のまま出る方が直せるので、読み込み時に弾く。
  # 欄の語彙(DISPLAY_*_KEYS)は、公開する文書が通す欄と同じものなので Catalogue が持つ。
  class DisplayShape
    def initialize(display)
      @display = display
    end

    # 見つけた問題の一覧。空なら、形としては読める display。
    def problems
      problems = unknown_key_problems(@display, Catalogue::DISPLAY_KEYS, 'display')
      problems << 'total_credits は正の数でなければなりません' unless positive_number?(@display['total_credits'])
      problems.concat(groups_problems(@display['groups'], @display['subtotals']))
      problems.concat(subtotal_problems(@display['subtotals']))
      problems
    end

    private

    def groups_problems(groups, subtotals)
      return ['groups は配列でなければなりません'] unless groups.is_a?(Array)

      groups.each_with_index.flat_map do |group, index|
        group_problems(group, "groups[#{element_name(group, index)}]", subtotals)
      end
    end

    def group_problems(group, path, subtotals)
      return ["#{path} はハッシュでなければなりません"] unless group.is_a?(Hash)

      problems = unknown_key_problems(group, Catalogue::DISPLAY_GROUP_KEYS + Catalogue::DISPLAY_DRAFT_KEYS, path)
      problems.concat(missing_string_problems(group, %w[id title], path))
      problems << "#{path}.required_credits は0以上の数でなければなりません" unless non_negative_number?(group['required_credits'])
      return problems << "#{path}.rows は配列でなければなりません" unless group['rows'].is_a?(Array)

      group['rows'].each_with_index do |row, index|
        covered = DisplayCoverage.covered?(row, group, subtotals)
        problems.concat(row_problems(row, "#{path}.rows[#{element_name(row, index)}]", covered))
      end
      problems
    end

    def row_problems(row, path, covered)
      return ["#{path} はハッシュでなければなりません"] unless row.is_a?(Hash)

      problems = unknown_key_problems(row, Catalogue::DISPLAY_ROW_KEYS + Catalogue::DISPLAY_DRAFT_KEYS, path)
      problems.concat(missing_string_problems(row, %w[id name], path))
      # 欄が無い・綴りが違うと false 扱いになり、算入上限が効いた判定の単位と食い違う数字が出る。
      unless Catalogue::BOOLEANS.include?(row['credits_from_check'])
        problems << "#{path}.credits_from_check は true か false でなければなりません"
      end
      problems.concat(row_requirement_problems(row, path, covered))
    end

    def missing_string_problems(hash, fields, path)
      fields.reject { |field| present_string?(hash[field]) }.map { |field| "#{path}.#{field} がありません" }
    end

    # 必要単位を持たない行は「内数」の行として、バーも判定も出さない。意図した行だけがそうなるよう、
    # 数えられる先も理由も無い行は弾く。綴り違いや読み落ちで必要単位が消えた行は、ここで止まる。
    #
    # 数えられる先が display から分かる行(枠がまとめている・章と同じ規則を指す)は、画面がその枠・章の単位を
    # 「この枠の22単位に含む」と出せるので、人が書いた説明文(required_label)は要らない(DisplayCoverage)。
    def row_requirement_problems(row, path, covered)
      credits = row['required_credits']
      return ["#{path}.required_credits は0以上の数か null でなければなりません"] unless credits.nil? || non_negative_number?(credits)

      return [] unless credits.nil? && !present_string?(row['required_label'])
      return [] if covered

      ["#{path} は required_credits が null なので、まとめる枠(subtotals)か、章と同じ規則を指すか、" \
       'required_label が必要です']
    end

    def subtotal_problems(subtotals)
      return [] if subtotals.nil?
      return ['subtotals は配列でなければなりません'] unless subtotals.is_a?(Array)

      subtotals.each_with_index.flat_map do |subtotal, index|
        path = "subtotals[#{element_name(subtotal, index)}]"
        next ["#{path} はハッシュでなければなりません"] unless subtotal.is_a?(Hash)

        problems = unknown_key_problems(subtotal, Catalogue::DISPLAY_SUBTOTAL_KEYS + Catalogue::DISPLAY_DRAFT_KEYS,
                                        path)
        unless non_negative_number?(subtotal['required_credits'])
          problems << "#{path}.required_credits は0以上の数でなければなりません"
        end
        problems
      end
    end

    # 欄の名前を1つずつ必須にせず、知らない欄を弾く。required_credits を綴り違いにした行は、
    # required_label があっても必要単位を失い、満たしていない要件が画面から消える。
    def unknown_key_problems(hash, allowed, path)
      unknown = hash.keys - allowed
      unknown.empty? ? [] : ["#{path} に未知の欄があります: #{unknown.join('、')}"]
    end

    # 直す人が探せるよう、エラーの場所は配列の添字ではなく要素の id で示す。id が無ければ添字。
    def element_name(element, index)
      id = element['id'] if element.is_a?(Hash)
      present_string?(id) ? id : index
    end

    def positive_number?(value) = number?(value) && value.positive?
    def non_negative_number?(value) = number?(value) && !value.negative?
    def number?(value) = value.is_a?(Numeric) && value.to_f.finite?
    def present_string?(value) = value.is_a?(String) && !value.strip.empty?
  end
end

