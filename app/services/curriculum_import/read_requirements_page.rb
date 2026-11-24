# frozen_string_literal: true

module CurriculumImport
  # 下書きの要件表の1ページを読み取り、結果を document に入れる。
  #
  # 読み取りは外部APIの呼び出しで数秒〜数十秒かかるので、その間はDBのロックを持たない。
  # 結果を入れるときに行を取り直してロックし、そのときの最新の document に統合する
  # (読み取りの前に読んでおいた document を書き戻すと、待っている間に他のページが足したものを消してしまう)。
  class ReadRequirementsPage
    def self.call(...) = new(...).call

    def initialize(curriculum, page, reader: RequirementsReader.new)
      @curriculum = curriculum
      @page = page
      @reader = reader
    end

    # 読めたら true。読めなかったらそのページだけ失敗にして false。
    def call
      raise ArgumentError, '公開済みの便覧は読み直せません。' if @curriculum.published?

      entry = @curriculum.page_entry(@page)
      raise ArgumentError, "#{@page}ページは、この下書きにありません。" unless entry

      record_success(read(entry))
      true
    rescue RequirementsReader::Error => e
      record_failure(e.message)
      false
    end

    private

    def read(entry)
      image_path = @curriculum.page_image_path(@page)
      raise RequirementsReader::Error, 'このページの画像が見つかりません。PDFを取り込み直してください。' unless image_path

      @reader.read(image_path: image_path, text: entry['text'])
    end

    def record_success(answer)
      @curriculum.with_lock do
        previous = @curriculum.page_entry(@page)['contributed']
        document = RequirementsMerge.withdraw(@curriculum.document, previous)
        document, contributed, warnings = RequirementsMerge.merge(document, answer)
        warnings = Array(answer['warnings']) + warnings
        @curriculum.update!(document: document,
                            pages: updated_pages('status' => 'read', 'error' => nil, 'contributed' => contributed,
                                                 'warnings' => warnings))
      end
    end

    # 失敗したページは、前に読めていた分(contributed)をそのまま残す。読み直しに失敗しただけで、消さない。
    def record_failure(message)
      @curriculum.with_lock do
        @curriculum.update!(pages: updated_pages('status' => 'failed', 'error' => message))
      end
    end

    def updated_pages(changes)
      @curriculum.pages.map { |entry| entry['page'] == @page ? entry.merge(changes) : entry }
    end
  end
end

