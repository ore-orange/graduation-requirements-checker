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
        fold(course['number']).presence || "name:#{fold(course['name'])}"
      end

      # 番号も名前も、同じ整え方をする(全種類の空白を取る・全角の英数字を半角にする・英字は小文字にする)。
      # 名前だけ strip で済ませると、AI が全角の空白や語中の空白を返しただけで、番号の無い科目(2024年度の特別講義Ⅴ・Ⅵ)が
      # 別の科目に見えて、二重に入る。英字を小文字にしても、実在の別の番号は混ざらない(2024年度の番号は、すべて大文字の接頭辞)。
      def fold(value)
        CourseNumber.normalize(value).downcase
      end

      # 読みの中身の指紋。同じ番号の行が複数あるとき、どの行かを見分ける。承認の要否は入れない(注記が後から付ける値で、
      # AI の読みの一部ではない)。単位は 2 と 2.0 を同じにする。
      # 言語・役割・要確認の理由・選べるかは入れない。同じ番号の2行がこれだけで違うときは、どちらを残すかが決まらない。
      def fingerprint(course)
        credits = course['credits']
        credits = credits.to_d.to_s if credits.is_a?(Numeric)
        Digest::SHA256.hexdigest(JSON.generate([identity(course), fold(course['name']), credits.to_s,
                                                course['category'].to_s, course['required'] == true]))[0, 16]
      end
    end
  end
end

