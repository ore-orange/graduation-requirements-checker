# frozen_string_literal: true

module CurriculumImport
  class DraftMerge
    # 科目の「AI の読み」を比べるための、正規形。読み直し(DraftMerge)と、確認画面で直す・消す側(CourseEdit)が、同じ数え方をする。
    #
    # 保存した科目の番号は整えてある(前後の空白を取る・全角を半角にする)が、読み直しの行は AI が返した生の値。
    # 片方だけ整えて比べると、モデルが番号の前後に空白を残しただけで、消した科目が黙って戻る。両方をここで整えて比べる。
    module CourseReading
      module_function

      # 同じ科目かどうか。番号があれば番号、無ければ科目名(分類表にしか載っていない科目)。空白だけの番号は、番号なし。
      def identity(course)
        CourseNumber.normalize(course['number']).presence || "name:#{course['name'].to_s.strip}"
      end

      # 読みの中身の指紋。同じ番号の行が複数あるとき、どの行かを見分ける。承認の要否は入れない(注記が後から付ける値で、
      # AI の読みの一部ではない)。単位は 2 と 2.0 を同じにする。
      def fingerprint(course)
        credits = course['credits']
        credits = credits.to_d.to_s if credits.is_a?(Numeric)
        Digest::SHA256.hexdigest(JSON.generate([identity(course), course['name'].to_s.strip, credits.to_s,
                                                course['category'].to_s, course['required'] == true]))[0, 16]
      end
    end
  end
end

