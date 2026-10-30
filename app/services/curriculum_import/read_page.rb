# frozen_string_literal: true

module CurriculumImport
  # 便覧の1ページを読み取りの窓口(CurriculumReader)に読ませ、結果を下書きの document に入れる。
  #
  # 読み取りは外部APIの呼び出しで数秒〜数十秒かかる。その間はDBのロックを持たない(持つと、画面の確認操作が止まる)。
  # 結果を入れるときに、行を取り直してロックし、そのとき最新の document に統合する。
  # 読み取りの前に手元に読んでおいた document を書き戻すと、待っている間に人が確認した科目を消してしまう。
  #
  # 学生の履修・成績は、ここを通らない。窓口に渡すのは、ページ画像とページのテキスト、区分・役割の一覧だけ。
  class ReadPage
    # 読み取りを続けられない理由。メッセージは、そのままページの行に出す。
    class Failure < StandardError; end

    def initialize(curriculum, reader:)
      @curriculum = curriculum
      @reader = reader
    end

    # 読めたら true。読まない種別・存在しないページは何も変えずに false。読めなかったらそのページだけ failed にして false。
    def call(number)
      entry = find_entry(@curriculum.pages, number)
      return false unless entry && Curriculum::READABLE_PAGE_KINDS.include?(entry['kind'])

      answer = ask(entry)
      record_success(number, entry['kind'], answer)
      true
    rescue Failure => e
      record_failure(number, e.message)
      false
    end

    private

    def find_entry(pages, number)
      pages.find { |page| page['page'] == number }
    end

    def ask(entry)
      number = entry['page']
      # 画像が正で、テキストは補助(依頼文にそう書いてある)。画像が無いまま文字だけで読ませない。
      image_path = @curriculum.page_image_path(number)
      raise Failure, "#{number}ページの画像が見つかりません。取り込み時に作れなかったため、読み取れません。" unless image_path

      text = entry['text'].to_s
      return @reader.read_requirements(text: text, image_path: image_path) if entry['kind'] == 'requirements'

      read_courses(text, image_path)
    rescue CurriculumReader::Error, ArgumentError => e
      raise Failure, e.message
    end

    # 区分は要件表の読み取りで先に決める。ページの順序は人が選ぶので、要件表より先に来ても落とさず、このページだけ失敗にする。
    def read_courses(text, image_path)
      document = @curriculum.document
      categories = Array(document['categories'])
      raise Failure, '区分がまだありません。先に要件表のページを読んでください。' if categories.empty?

      @reader.read_courses(text: text, image_path: image_path, categories: categories, roles: Array(document['roles']))
    end

    # kind は、読み取りを頼んだときの種別。待っている間に人が種別を替えていたら、その答えは別の種別の形なので入れない。
    # どんな形の答えでも500にはしない(入れられなければ、そのページだけ failed にする)。
    def record_success(number, kind, answer)
      @curriculum.with_lock do
        entry = find_entry(@curriculum.pages, number)
        raise Failure, '読み取りの途中でページの種別が変わったため、結果を入れていません。もう一度読んでください。' unless entry && entry['kind'] == kind

        save_merged(number, entry, answer)
      end
    rescue Failure
      raise
    rescue StandardError => e
      Rails.logger.warn("読み取りの結果を下書きに入れられませんでした: #{e.class}: #{e.message}")
      raise Failure, '読み取りの結果を下書きに入れられませんでした。読み取りの答えの形が想定と違います。'
    end

    def save_merged(number, entry, answer)
      document = @curriculum.document.deep_dup
      merge = DraftMerge.new(document, curriculum: @curriculum, page: number, previous: entry['contributed'])
      contributed, warnings = merge_page(merge, document, entry, answer)
      # 注記は読む順番に関わらず効かせる。科目表が先でも、あとで要件表を読めば、その時点で科目に当たる。
      ApprovalNotes.apply(document)
      warnings << ApprovalNotes.course_page_warning(document, number, entry['text']) if entry['kind'] == 'courses'
      @curriculum.document = document
      @curriculum.pages = replace_entry(number, 'status' => 'read', 'error' => nil,
                                                'warnings' => (warnings + merge.warnings).compact.uniq,
                                                'contributed' => contributed)
      @curriculum.save!
    end

    # 戻り値は [このページが足したものの記録, 警告の文]。
    def merge_page(merge, document, entry, answer)
      return [merge.courses(answer), []] unless entry['kind'] == 'requirements'

      # 要件表の注記から、区分ごとの承認の注記を拾う。ほかのページの科目へ当てるのは ApprovalNotes.apply。
      notes, unresolved = ApprovalNotes.detect(answer, entry['page'])
      ApprovalNotes.replace_page_notes(document, entry['page'], notes)
      warnings = unresolved.map { |text| "承認の注記らしい文がありますが、対象の区分が分からず科目に反映していません: #{text}" }
      warnings << ApprovalNotes.requirements_page_warning(entry['text'], notes.any? || unresolved.any?)
      [merge.requirements(answer), warnings]
    end

    def record_failure(number, message)
      @curriculum.with_lock do
        @curriculum.pages = replace_entry(number, 'status' => 'failed', 'error' => message)
        @curriculum.save!
      end
    end

    def replace_entry(number, changes)
      @curriculum.pages.map { |page| page['page'] == number ? page.merge(changes) : page }
    end
  end
end

