# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 区分・役割のように key で足し合わせるものの統合。先にあるもの(別のページが足した・人が直した)を優先する。
    module KeyedMerge
      private

      # key で足す。先にあるもの(別のページが足した・人が直した)を優先し、同じ key の読み取りでは上書きしない。
      # 同じ key で名前が違えば、先を残して警告に出す(総単位の食い違いと同じ扱い)。
      def add_keyed(target, incoming, noun)
        incoming.to_a.each do |entry|
          existing = target.find { |other| other['key'] == entry['key'] }
          if existing.nil?
            target << entry
          elsif existing[CONFIRMED]
            # 人が直した区分は、読み直した内容で変えない。数えるかどうかの「数えない側に倒す」もしない(人が数えると決めた)。
            @warnings.concat(Differences.kept_category(noun, existing, entry))
          else
            @warnings.concat(keyed_differences(noun, existing, entry))
            # 総単位に数えるかが食い違うときは、数えない側に倒す。数える側に倒すと単位の水増しになり、数えない側は要確認になる。
            existing['counts_toward_total'] = false if entry['counts_toward_total'] == false
          end
        end
      end

      # 名前と、総単位に数えるかどうか(区分だけの欄。単位が総単位に入るかを決める)の食い違い。
      def keyed_differences(noun, existing, entry)
        differences = []
        if existing['label'] != entry['label']
          differences << "#{noun} #{entry['key']} の名前が別のページと食い違います(先: #{existing['label']}、このページ: #{entry['label']})。"
        end
        if existing['counts_toward_total'] != entry['counts_toward_total']
          differences << "#{noun} #{entry['key']} の「卒業の総単位に数えるか」が別のページと食い違います" \
                         "(先: #{existing['counts_toward_total']}、このページ: #{entry['counts_toward_total']})。" \
                         '数えない(false)側に合わせました。確かめてください。'
        end
        differences
      end

      # roles は任意の欄。読み取りが返したときだけ作る(欄が無ければ、規則の paths から役割のキーを導く)。
      def add_roles(incoming)
        return if incoming.blank?

        add_keyed(@document['roles'] ||= [], incoming, '役割')
      end
    end
  end
end

