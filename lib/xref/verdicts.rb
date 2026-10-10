# frozen_string_literal: true

module Xref
  # The journal of verified findings: what was checked against the first source
  # and how it turned out.
  #
  # The reason this exists is a MEASUREMENT, not tidiness. In a new layer of the
  # index false findings outnumber real ones two or three to one, and that is a
  # property of the layer rather than sloppiness of the parser. Seven classes,
  # counted over two days (2026-10-08…09):
  #
  #   broken examples in documents      137 → 7    (95 % false)
  #   broken links                      632 → 15   (98 %)
  #   `rewrite … last`                   25 → 2    (92 %)
  #   missing translations               22 → 6    (73 %)
  #   references to a non-existent column 13 → 4   (69 %)
  #   dead Stimulus controllers           3 → 1    (67 %)
  #
  # Each of those checks cost half an hour of reading the first source, and all
  # that knowledge used to stay in a commit message. Here it sits next to the
  # finding and does two things nothing did before:
  #
  #   * a finding with the verdict "false" NO LONGER REACHES the report —
  #     otherwise it gets re-verified every time, and people learn to skim the
  #     report instead of reading it;
  #   * next to each class its reliability is printed: "13 verified, 9 false".
  #     That tells the reader how much to trust a NEW finding of the same class,
  #     and no such number existed anywhere before.
  #
  # A verdict of "false" HIDES a finding, which means it can hide a real problem
  # that appears later in the same place. So it is anchored to the SHA of the
  # file: the file changed — the verdict is STALE, and the finding returns to the
  # report with a mark. For a class with no file of its own the anchor is the
  # calling file or the first document; one class is left with no anchor at all
  # — an index inside the database — and the report says of it "removed FOREVER".
  module Verdicts
    REAL = 'настоящая'
    WRONG = 'ложная'

    # How it was verified. The list does not forbid anything, it suggests: a
    # word of your own is accepted, but the descending order of evidential
    # strength is exactly this — execution beats the schema, the schema beats
    # the eye.
    WAYS = ['исполнением', 'схемой', 'данными', 'логами', 'спекой', 'глазами'].freeze

    # A living document versus a historical record. In an audit, a journal, a
    # task artefact or a session goal a stale path is THE TRUTH ABOUT THE PAST
    # and is not a finding: rewriting it would mean forging the record. The rule
    # is written here rather than in the report, because the report and the
    # finding class must count identically — otherwise `findings` shows 1,905
    # where `docs` shows 364, and neither can be trusted.
    LIVING_DOC = <<~SQL.squish
      doc not like '.claude/goal-%' and doc not like 'doc/schema/%'
      and doc not like 'doc/memory-bank/%' and doc not like 'doc/auto/%'
      and doc not like 'doc/goals-merge-parts/%'
      and doc !~ 'audit|findings|-20[0-9]{6}'
    SQL

    # A finding class: where it comes from, what identifies it and how it is
    # displayed.
    #
    # `subject` is the expression that IDENTIFIES a finding, and it is written
    # exactly once: both the listing of the class and the filtering out of
    # reports go through it. Two spellings would drift apart silently, and a
    # verdict would stop recognising its own finding.
    #
    # `path` is the file whose SHA ages the verdict. `null` means "never goes
    # stale", and that is only honest where the finding does not live in a file
    # of the tree.
    KINDS = {
      'column' => {
        title: 'код ходит в колонку, которой нет',
        view: 'v_column_blind',
        where: "kind = 'БОЕВОЙ КОД'",
        subject: "path || ':' || table_name || '.' || column_name",
        path: 'path',
        show: "table_name || '.' || column_name || ' (' || mode || ')'"
      },
      'locale' => {
        title: 'ключ зовут, перевода нет',
        view: 'v_i18n_usage',
        where: 'not in_store and not has_default',
        subject: 'key',
        # A key has no file of its own, but it has a CALLING file, and editing
        # that file is what can overturn the verdict: three of the six verified
        # gaps turned out false precisely because only a spec called the key.
        # An anchor on the first caller is incomplete (a key is called from
        # several places), and the report says so.
        path: 'paths[1]',
        show: "key || ' — в ' || files || ' местах'"
      },
      'locale_pattern' => {
        title: 'собранный ключ не совпал ни с одним ключом хранилища',
        view: 'v_i18n_pattern',
        where: "verdict = 'НИ ОДНОГО КЛЮЧА'",
        subject: 'pattern',
        path: 'paths[1]',
        show: "pattern || ' — в ' || files || ' файлах'"
      },
      'css_file' => {
        title: 'таблицу стилей не подключает никто',
        view: 'v_css_unreachable',
        where: "kind = 'КАНДИДАТ НА СНЯТИЕ'",
        subject: 'path',
        path: 'path',
        show: "path || ' — классов ' || classes"
      },
      'css_class' => {
        title: 'класс объявлен, а не поминает никто',
        view: 'v_css_class_usage',
        where: "verdict = 'НЕ ПОМИНАЕТ НИКТО'",
        subject: "declared_in || ':' || name",
        path: 'declared_in',
        show: "name || ' в ' || declared_in"
      },
      'doc_code' => {
        title: 'пример в документе не разобрался',
        view: 'v_doc_code',
        where: "verdict = 'НЕ РАЗОБРАЛСЯ'",
        subject: "doc || ':' || lines[1]",
        path: 'doc',
        show: "coalesce(lang, '?') || ' — ' || detail"
      },
      'doc_link' => {
        title: 'ссылка в документе ведёт в пустоту',
        view: 'v_doc_link_broken',
        where: 'true',
        subject: "doc || ' → ' || target",
        path: 'doc',
        show: 'target'
      },
      'doc_path' => {
        title: 'живой документ называет файл, которого нет',
        view: 'v_doc_path',
        where: "kind = 'НЕТ ТАКОГО ФАЙЛА' and #{LIVING_DOC}",
        subject: "doc || ' → ' || target",
        path: 'doc',
        show: 'target'
      },
      'doc_table' => {
        title: 'в запросе документа таблица, которой нет в схемах',
        view: 'v_doc_table_unknown',
        where: 'true',
        subject: 'table_name',
        path: 'docs_list[1]',
        show: "table_name || ' — в ' || docs || ' документах'"
      },
      'front' => {
        title: 'дефект конфигурации фронта',
        view: 'v_conf_defect',
        where: 'true',
        subject: "path || ':' || lines[1] || ':' || defect",
        path: 'path',
        show: 'defect'
      },
      'script' => {
        title: 'опасное место в скрипте',
        view: 'v_sh_dangerous',
        where: 'true',
        subject: "path || ':' || lines[1]",
        path: 'path',
        show: 'line_text'
      },
      'stimulus_use' => {
        title: 'шаблон включает незарегистрированный контроллер',
        view: 'v_stimulus_use',
        where: 'not registered',
        subject: "path || ':' || identifier",
        path: 'path',
        show: 'identifier'
      },
      'stimulus_action' => {
        title: 'действие указывает на метод, которого нет',
        view: 'v_stimulus_action',
        where: "verdict <> 'метод есть'",
        subject: "path || ':' || identifier || '#' || method",
        path: 'path',
        show: "identifier || '#' || method || ' — ' || verdict"
      },
      'stimulus_orphan' => {
        title: 'контроллер зарегистрирован, а не включает его никто',
        view: 'v_stimulus_registry',
        where: 'templates = 0',
        subject: 'identifier',
        path: 'source',
        show: "identifier || ' — методов ' || methods"
      },
      'js_import' => {
        title: 'импорт ведёт в никуда',
        view: 'code_refs',
        where: "kind = 'js_import_missing'",
        subject: "path || ' → ' || token",
        path: 'path',
        show: 'token'
      },
      'list_defect' => {
        title: 'дефект в списке полей',
        view: 'v_column_list_defect',
        where: 'true',
        subject: "path || ':' || list_name || '.' || column_name",
        path: 'path',
        show: "kind || ': ' || list_name || '.' || column_name"
      },
      'index_unused' => {
        # A row of this class is AN INDEX IN ONE SOURCE: the same index appears
        # here three times if it goes unread in three data centres, and that is
        # not a duplicate but three different statements with three different
        # observation windows.
        title: 'индекс не читает никто (по источнику)',
        view: 'v_index_unused',
        where: 'true',
        subject: "source || ':' || table_name || '.' || index_name",
        path: nil,
        show: "index_name || ' на ' || table_name || ' (' || size || ')'"
      }
    }.freeze

    class << self
      def kinds
        KINDS.keys
      end

      def kind(name)
        KINDS[name.to_s]
      end

      def kind!(name)
        kind(name) || raise(Xref::Error, "разряд находок неизвестен: #{name}. Есть: #{kinds.join(', ')}")
      end

      def title(name)
        kind(name)&.fetch(:title) || name.to_s
      end

      # The verdict word, from whatever was typed. Both a short form and Latin
      # letters are accepted: verdicts are written by hand, one at a time, and
      # there is no need for one more chance to mistype.
      def word(input)
        case input.to_s.strip.downcase
        when 'ложная', 'ложь', 'л', 'false', 'f', 'no', 'wrong' then WRONG
        when 'настоящая', 'правда', 'н', 'real', 'r', 'yes', 'true' then REAL
        end
      end

      def word!(input)
        word(input) || raise(Xref::Error,
                             "вердикт должен быть «#{WRONG}» или «#{REAL}», а не «#{input}»")
      end

      # Listing the open findings of a class: the subject, the file and a line
      # for the eye. Those filtered out by the journal do not appear here —
      # "open" means "not yet dealt with".
      def open_sql(name, limit: nil, only: nil)
        spec = kind!(name)
        conditions = [spec[:where], filter_sql(name)]
        conditions << only if only.present?
        <<~SQL.squish
          select #{spec[:subject]} as subject,
                 #{spec[:path] || 'null::text'} as path,
                 #{spec[:show]} as show
          from #{spec[:view]}
          where #{conditions.join(' and ')}
          order by 1#{limit ? " limit #{limit.to_i}" : ''}
        SQL
      end

      # How many findings of the class are OPEN (the journal taken into account).
      def count_sql(name)
        spec = kind!(name)
        <<~SQL.squish
          select count(*) from #{spec[:view]}
          where #{spec[:where]} and #{filter_sql(name)}
        SQL
      end

      # The condition "this finding carries no verdict of false". It is
      # substituted into the WHERE of the reports themselves, so it is written
      # with the class's subject expression rather than as a join: the reports
      # read the finding views directly.
      def filter_sql(name)
        spec = kind!(name)
        "#{spec[:subject]} not in (select subject from v_finding_hidden where kind = '#{name}')"
      end

      # Does such a finding exist at all — the check before a verdict is
      # written. A verdict about something the report does not contain is
      # garbage that later silently hides a namesake. The subject arrives
      # ALREADY quoted: the connection quotes it, not string concatenation.
      def lookup_sql(name, quoted_subject)
        spec = kind!(name)
        <<~SQL.squish
          select #{spec[:subject]} as subject,
                 #{spec[:path] || 'null::text'} as path,
                 #{spec[:show]} as show
          from #{spec[:view]}
          where #{spec[:where]} and #{spec[:subject]} = #{quoted_subject}
          limit 1
        SQL
      end
    end
  end
end
