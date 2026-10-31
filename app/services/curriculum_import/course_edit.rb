# frozen_string_literal: true

module CurriculumImport
  # 確認画面で、人が1科目について確認した・直した・消した・足した内容を、下書きの document に入れる。
  #
  # 守るべきことは4つ。
  #
  # 1. 直した科目は、読み直しから守る。値が変わった科目には confirmed を付ける(DraftMerge が、確認済みの科目を外さず、
  #    読み直した側の行も採らない)。「確認した」だけの操作も同じ印を付ける。直していない科目に印は付けない。
  #    値を変えながら confirmed を外すことはできない(直した値は、必ず守られる)。
  # 2. 読み直しの突き合わせは、AI が読んだときの科目番号(と無ければ名前)で行う。人が番号や名前を直すと、AI の読みとは
  #    別のものに見えて、読み直しで同じ行が二重に入る。だから、直す前の読みを read_as に残す(DraftMerge が照らす)。
  #    消した科目は、読み直しが戻さないよう、消した記録(removed_by_human、kind=course)に同じ読みを残す。
  # 3. 人が科目を確認したら、承認の注記が付けた印(approval_by_note)を外す。印を残すと、あとで注記を外したときに、
  #    人が確認した科目の承認まで巻き込んで外れる(ApprovalNotes::Removal)。承認の要否を直したときも外す。
  # 4. 1科目ぶんだけを、jsonb_set で書く(Storage)。画面は、開いたときの科目の指紋(rev)を送り返す。開いたあとに
  #    その科目が変わっていたら、古い画面の値で上書きせず、断る(確認は、画面で見た値についての確認だから)。
  #
  # 送られた欄だけを直す(送られなかった欄は、いまの値のまま)。エラーが1つでもあれば、何も保存しない。
  # 科目は params の key で指す。key が無いときだけ、number で指す(確認の1操作だけを送る呼び出し向け)。
  class CourseEdit
    include RequirementsEdit::Coercion
    include Storage
    include Adding

    Problem = RequirementsEdit::Problem

    # changed は、直した欄の名前。key は、画面が取り直す科目の key(消したときは nil)。
    # stale は、画面を開いたあとに科目が変わっていた(または消えていた)ため断ったとき。
    Result = Struct.new(:problems, :key, :changed, :notes, :stale, keyword_init: true) do
      def ok? = problems.empty?
      def errors = problems.map(&:message)
    end

    FIELDS = { 'number' => :text, 'name' => :text, 'credits' => :number, 'category' => :text, 'required' => :flag,
               'requires_approval' => :flag, 'selectable' => :flag, 'language' => :text, 'review_reason' => :text,
               'roles' => :list }.freeze
    LABELS = { 'number' => '科目番号', 'name' => '科目名', 'credits' => '単位', 'category' => '区分', 'required' => '必修',
               'requires_approval' => '指導教員の承認が要るか', 'selectable' => '学生が選べるか', 'language' => '言語',
               'review_reason' => '要確認の理由', 'roles' => '役割', 'confirmed' => '確認済み' }.freeze
    # 手で足す科目に要る欄。読み取りが返す欄から、読み落とした科目を足すのに足りる分。
    ADDED_REQUIRED = %w[number name credits category].freeze
    # 手で足す科目の出典。便覧のページから読んだものではないので、ページ番号の代わりにこう書く。
    ADDED_SOURCE_PAGE = '手で追加'
    MAX_CREDITS = 20
    BY_NOTE = ApprovalNotes::BY_NOTE
    READ_AS = 'read_as'
    # 直す前の(AI が読んだままの)中身の指紋。最初に値を直したときに残す。消した科目の記録が、同じ番号の行のどれかを見分けるのに使う。
    READ_FP = 'read_fp'
    # 承認の注記があとから付いて、確認済みの科目の承認が変わったときの印(ApprovalNotes)。人がもう一度確認すると外れる。
    REVIEW_AGAIN = ApprovalNotes::REVIEW_AGAIN
    ADDED_BY_HAND = 'added_by_hand'

    # 科目の指紋。画面を開いたときの値と、保存のときの値を比べる。
    def self.fingerprint(course)
      Digest::SHA256.hexdigest(JSON.generate(course))[0, 16]
    end

    def initialize(curriculum, params)
      @curriculum = curriculum
      @params = params.to_h.with_indifferent_access
      @problems = []
      @key = nil
    end

    # 行をロックした中で呼ぶこと。
    def call
      document = @curriculum.document
      return failure('この下書きの形が読めません(document がハッシュではありません)。') unless document.is_a?(Hash)
      return add_course(document) if truthy?(@params[:added_by_hand])

      courses = document['courses']
      return failure('この下書きには科目がありません。画面を開き直してください。', stale: true) unless courses.is_a?(Array)

      locate(courses) || update_course(document, courses)
    end

    private

    def truthy?(value) = TRUE_VALUES.include?(value)

    def result(changed = [], notes = [])
      Result.new(problems: @problems, key: @key, changed: changed, notes: notes, stale: false)
    end

    def failure(message, stale: false)
      Result.new(problems: [Problem.new(message, 'course', @key)], key: @key, changed: [], notes: [], stale: stale)
    end

    def error(message, *)
      @problems << Problem.new(message, 'course', @key)
      nil
    end

    # 科目を指す。見つからない・曖昧なときは、失敗の結果を返す(見つかれば @index と @course に入れて nil)。
    def locate(courses)
      @index = find_index(courses)
      return failure('この科目は見つかりません。読み直しなどで変わった可能性があります。画面を開き直してください。', stale: true) unless @index

      @course = courses[@index].deep_dup
      @key = @course['key']
      nil
    end

    def find_index(courses)
      key = @params[:key].to_s
      return courses.index { |course| course.is_a?(Hash) && course['key'] == key } if key.present?

      wanted = CourseNumber.normalize(@params[:number])
      return if wanted.empty?

      found = courses.each_index.select do |i|
        courses[i].is_a?(Hash) && CourseNumber.normalize(courses[i]['number']) == wanted
      end
      found.first if found.one?
    end

    def update_course(document, courses)
      return stale_course if @params[:rev].present? && @params[:rev] != self.class.fingerprint(courses[@index])
      return remove_course if truthy?(@params[:_destroy])

      before = @course.deep_dup
      changed = apply_fields(document, courses)
      state = confirmation(changed)
      return result if @problems.any?

      settle(before, changed, state)
    end

    def stale_course
      failure('この科目は、画面を開いたあとに変わっています(読み取りや、ほかの操作)。何も保存していません。' \
              '画面を開き直して、もう一度直してください。', stale: true)
    end

    # ---- 直す・確認する ----

    # 送られた欄を科目に当てる。値が変わった欄の名前を返す。number は key が無いときは科目を指す値なので、直さない。
    def apply_fields(document, courses)
      FIELDS.filter_map do |field, kind|
        next unless @params.key?(field)
        next if field == 'number' && @params[:key].blank?

        value = checked_value(field, kind, document, courses)
        next if value == :invalid || same?(kind, field, value, @course[field])

        @course[field] = value
        field
      end
    end

    def checked_value(field, kind, document, courses)
      value = coerce(@params[field], kind, "#{label}の#{LABELS.fetch(field)}")
      return value if value == :invalid

      check(field, value, document, courses)
    end

    # 「確認済み」にする・外す。値を変えたときは、必ず確認済みにする(直した値を、読み直しの上書きから守る)。
    # 戻り値は、確認済みの状態(true/false)。
    def confirmation(changed)
      explicit = @params.key?(:confirmed) ? coerce(@params[:confirmed], :flag, "#{label}の確認済み") : nil
      return true if changed.any?

      explicit.nil? || explicit == :invalid ? @course['confirmed'] == true : explicit
    end

    def settle(before, changed, confirmed)
      remember_read(before, changed)
      @course['confirmed'] = confirmed if confirmed || @course.key?('confirmed')
      clear_review_again(changed)
      # 人が確認した、または承認の要否を人が決めた科目は、注記が付けた印を外す(あとで注記を外しても、巻き込まれない)。
      @course.delete(BY_NOTE) if confirmed || changed.include?('requires_approval')
      return result([], ['変えた箇所はありませんでした。']) if @course == before

      write_course(@index, @course)
      result(changed, [saved_note(changed, confirmed)])
    end

    # 確認する・外す・直すのどれでも、「もう一度確認してください」の印は役目を終える。
    def clear_review_again(changed)
      @course.delete(REVIEW_AGAIN) if changed.any? || @params.key?(:confirmed)
    end

    def saved_note(changed, confirmed)
      return "#{label}を確認済みにしました。" if changed.empty? && confirmed
      return "#{label}の確認を外しました。直した値も、このページを読み直すと、AI の読みに入れ替わります。" if changed.empty?

      "#{label}を直しました(#{changed.map { |field| LABELS.fetch(field) }.join('・')})。確認済みの科目として残り、読み直しでは上書きしません。"
    end

    # 人が初めて値を直すとき、直す前の(AI が読んだままの)中身を指紋で残す(消した科目の記録が使う)。
    # 番号や名前を直すと、AI の読みとは別の科目に見える。直す前の読みも残して、読み直しが二重に入れないようにする(最初の読みを残す)。
    def remember_read(before, changed)
      return if changed.empty? || @course[ADDED_BY_HAND]

      @course[READ_FP] ||= DraftMerge::CourseReading.fingerprint(before)
      return unless changed.intersect?(%w[number name])
      return if @course[READ_AS] || identity(before) == identity(@course)

      @course[READ_AS] = identity(before)
    end

    # DraftMerge の読み直しと同じ数え方(CourseReading)。
    def identity(course) = DraftMerge::CourseReading.identity(course)

    # ---- 消す ----

    # AI が読んだ科目を消すときは、読み直しが戻さないよう、読みを記録に残す。手で足した科目は、記録なしで消す。
    def remove_course
      tombstone = removal_record unless @course[ADDED_BY_HAND]
      delete_course(@index, tombstone)
      @key = nil
      note = '読み直しでは、同じ読みの行は入れません(読み直した内容が変わっていれば、警告をつけて入ります)。' if tombstone
      result([], ["#{label}を消しました。#{note}"])
    end

    # 消した科目を足したページ(読み直しの対象)と、AI の読み。ページが分からなければ、記録は要らない
    # (どのページを読み直しても、この科目を足すことは無い)。
    def removal_record
      page = @curriculum.pages.find { |entry| Array(entry.dig('contributed', 'courses')).include?(@course['key']) }
      return unless page

      { 'kind' => 'course', 'id' => @course['key'], 'page' => page['page'],
        'identity' => @course[READ_AS] || identity(@course),
        'fingerprint' => @course[READ_FP] || DraftMerge::CourseReading.fingerprint(@course) }
    end

    # ---- 値の検め ----

    def label
      @label ||= begin
        course = @course || {}
        name = course['name'].presence || @params[:name].presence
        [course['number'].presence || @params[:number].presence, ("「#{name}」" if name)].compact.join.presence || '科目'
      end
    end

    # 値の検め。読めなければ error を積んで :invalid を返す。
    def check(field, value, document, courses)
      case field
      when 'number' then check_number(value, courses)
      when 'name' then require_text(value, field)
      when 'credits' then check_credits(value)
      when 'category' then check_category(value, document)
      else value
      end
    end

    def require_text(value, field)
      return value if value.present?

      invalid("#{label}の#{LABELS.fetch(field)}を入れてください。")
    end

    # 番号は、表記の揺れ(全角・空白)をそろえて持つ。ほかの科目と同じ番号は、判定が片方しか使わないので、断る。
    def check_number(value, courses)
      return invalid("#{label}の科目番号を入れてください。") if value.blank?

      number = CourseNumber.normalize(value)
      taken = courses.grep(Hash).any? do |other|
        other['key'] != @course&.dig('key') && CourseNumber.normalize(other['number']) == number
      end
      return invalid("科目番号「#{number}」の科目は、すでにあります。同じ番号の科目は足せません(判定は片方しか使いません)。") if taken

      number
    end

    def check_credits(value)
      return invalid("#{label}の単位を入れてください。") if value.nil?
      return invalid("#{label}の単位は0〜#{MAX_CREDITS}の数で入れてください(入れた値: #{value})。") unless value.between?(0, MAX_CREDITS)

      value
    end

    # 便覧に無い区分の科目は、どの行にも出ず、どの規則にも数えられない(単位が反映されない)。選べる区分は便覧のものだけ。
    def check_category(value, document)
      return invalid("#{label}の区分を選んでください。") if value.blank?

      keys = Array(document['categories']).grep(Hash).pluck('key')
      return value if keys.include?(value)

      invalid("#{label}の区分「#{value}」は、この便覧の区分にありません。")
    end
  end
end

