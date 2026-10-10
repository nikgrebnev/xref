# frozen_string_literal: true

# The cross-reference index. Step one: the schemas of every source in one local
# database, plus a report of the differences between them.
#
#   bin/xref schema                       — take every source
#   bin/xref schema SOURCES=prod-a,prod-b — only these
#   bin/xref drift                        — what does not match where
#   bin/xref column NAME=g_marriage       — where a column lives
#   bin/xref code                         — parse the code (incrementally)
#   bin/xref where NAME=big_users.g1      — where it is touched
#   bin/xref blind                        — where the index is powerless

# Catch the code index up with the current state of the files.
#
# Called both from xref:code and before every query: an index answering about
# yesterday's code is worse than no index. The comparison goes by SHA-1, so the
# usual price is a fraction of a second for the walk and for parsing the two or
# three files that changed.
def xref_scan_code(full: false, quiet: false)
  require 'digest'

  Xref::Store.migrate!
  known = Xref::Store.known_names
  # NO SCHEMA IS A REASON TO SAY SO, NOT A REASON TO PARSE NOTHING.
  #
  # Only one layer depends on the names from a schema — the candidates by word
  # (`token`), and the column binding that goes with it. Calls, renders,
  # documents, styles, JavaScript, the dead-code sweep need no schema at all.
  # Until this was split, a fresh installation with no source configured got NO
  # index whatsoever and a line telling it to run something else: the tool
  # refused to answer questions it could answer. Found on the first standalone
  # run, 2026-10-10.
  unless known.any? || quiet
    puts '  ! снимков схем нет: разбор пойдёт БЕЗ слоя кандидатов по именам'
    puts '    (это неполнота, а не отсутствие связей — bin/xref schema её закрывает)'
  end
  model_tables = Xref::Store.model_tables
  app_constants = Xref::Store.app_constant_names
  # The composition of the field lists from the PREVIOUS parse: a loop over a
  # list reads exactly the columns in it. A second-order input — the list is
  # assembled by the same parse — so the full picture appears on the second run,
  # and that is more honest than not linking them at all.
  column_lists = Xref::Store.column_lists
  # A digest of the parse inputs: if a schema or the application facts changed,
  # EVERYTHING has to be parsed even though no file changed.
  inputs_sha = Xref::Store.input_digest(known: known, model_tables: model_tables,
                                        app_constants: app_constants,
                                        column_lists: column_lists,
                                        idioms: Xref.idiom_digest,
                                        scanner: Xref::Store.scanner_digest)

  # `.builder` did not get here at once: the production logs found it — rss
  # templates were rendered thousands of times while the index knew nothing of
  # such files.
  # `.md` is here because documentation is as much a source of statements about
  # the tree as code is, and it ages silently. Of 23,337 tracked files 12,243
  # are `.md`, and the index knew nothing about them.
  # Configuration and scripts for the same reason as documentation: environment
  # keys are read through ERB in `.yml`, `.sh` holds both SQL and keys, and
  # `.conf` holds the whole delivery of the site — and the index saw none of the
  # three until now.
  # `.ts/.tsx/.mts` are THE GATE of the walk, and without them the JavaScript
  # layer is not scanned AT ALL. A TypeScript project (a second one,
  # 2026-10-09) got six false findings: three "the controller is not
  # registered" with the registration sitting in `application.ts`, and three
  # "NO SUCH METHOD" with the methods in place. That is the worst kind of
  # breakage — the tool does not stay silent, it lies.
  # `.css/.scss` are the last whole layer: 43 of our own files, 22 thousand
  # lines, were invisible to the index, and the question "which styles are not
  # needed" had nothing to answer with. Vendored stylesheets are filtered out
  # below together with the rest of the vendor directory.
  extensions = %w[.rb .rake .ru .erb .haml .slim .builder .jbuilder .js .jsx .mjs
                  .ts .tsx .mts .sql .css .scss .sass .less
                  .md .markdown .yml .yaml .json .sh .bash .conf]
  # Schema dumps in db/ are a schema rather than code that touches one: a legacy
  # structure dump holds a thousand shards `auth_sidNNN`, and all of them landed
  # in "the code addresses a table". The index does not parse its own files
  # either: its DDL is about another database.
  skip = %r{\A(vendor/|node_modules/|public/|db/[^/]+\.sql\z|lib/xref/|lib/tasks/xref\.rake\z)}

  files = Xref.utf8(`git -C #{Xref.root} ls-files -z`).split("\0")
           .select { |f| extensions.include?(File.extname(f)) }
           .reject { |f| f.match?(skip) }

  stored = Xref::Store.code_file_stamps

  # What to parse and whose SHA to compute for that lives in Xref::ScanPlan:
  # this is a gate, it breaks in the dangerous direction (skipping a changed file
  # means answering from stale content while looking fresh), and it has a spec.
  # The vanished are always counted: otherwise with FULL=1 rows remain from files
  # that dropped out of the walk.
  plan = Xref::ScanPlan.call(
    files, stored: stored, inputs_sha: inputs_sha, full: full,
    mtime: ->(path) { p = Xref.root.join(path); File.file?(p) ? File.mtime(p).to_f : nil },
    digest: ->(path) { Digest::SHA1.file(Xref.root.join(path)).hexdigest }
  )
  current = plan.current
  mtimes = plan.mtimes
  removed = plan.removed
  changed = plan.changed
  stale_inputs = !full && changed.size == current.size && current.size.positive? &&
                 stored.any? && stored.values.none? { |(_, inputs, _)| inputs == inputs_sha }

  Xref::Store.delete_code_files(removed) if removed.any?
  if changed.empty?
    puts "файлов под индексом: #{current.size}, индекс кода уже свежий" unless quiet
    return
  end

  if stale_inputs
    note = 'сменились входы разбора (схема, факты приложения или сам разборщик) — разбираем всё заново'
    puts quiet ? "(#{note})" : "  ! #{note}"
  end

  unless quiet
    puts "файлов под индексом: #{current.size}, изменилось: #{changed.size}, исчезло: #{removed.size}"
    puts '  ! моделей в индексе нет — обращения через AR не привязаны к таблицам (bin/xref app)' if model_tables.empty?
  end

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  done = 0
  changed.each do |path, sha|
    full_path = Xref.root.join(path)
    source = File.read(full_path, encoding: 'UTF-8').scrub('')
    refs = Xref::CodeScanner.new(path, source, known: known, model_tables: model_tables,
                                       app_constants: app_constants,
                                       column_lists: column_lists).scan
    Xref::Store.write_code_file(path, sha: sha, lang: Xref::CodeScanner.language(path),
                                        bytes: File.size(full_path), refs: refs,
                                        inputs_sha: inputs_sha, mtime: mtimes[path])
    done += 1
    if !quiet && (done % 500).zero?
      puts "  #{done}/#{changed.size}"
      $stdout.flush
    end
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  if quiet
    puts format('(индекс догнал %d изменённых файлов за %.1f с)', done, elapsed) if done.positive?
  else
    puts format('разобрано %d файлов за %.1f с', done, elapsed)
  end
end

# Before a query the index is caught up. XREF_NO_REFRESH=1 — do not catch up.
#
# And the state we answer from is printed immediately. That is not decoration:
# the code index catches itself up while the schema snapshots do not, and a query
# answering from a week-old snapshot looked exactly like a fresh one. That is how
# the index insisted for a month that two tables were absent from two
# environments — while they held two hundred thousand rows.
def xref_fresh!
  # The DDL is idempotent and runs on every command; with XREF_NO_REFRESH=1 the
  # parse is skipped while the index schema still has to be applied — otherwise
  # the state is asked of columns that do not exist yet.
  Xref::Store.migrate!
  xref_scan_code(quiet: true) if ENV['XREF_NO_REFRESH'].blank?
  xref_state!
end

# One state line plus, if there are any, the loud warnings.
# Printed exactly once per run: the tasks call each other.
def xref_state!
  return if @xref_state_shown

  @xref_state_shown = true
  state = Xref::Store.freshness
  return if state.nil?

  age = state['schema_at'] ? ((Time.now - state['schema_at'].to_time) / 3600).round : nil
  parts = ["файлов #{state['files']}"]
  parts << (age ? "снимкам схем #{age} ч" : 'снимков схем НЕТ')
  parts << "слепых мест #{state['blind']}"
  puts "[индекс: #{parts.join(', ')}]"

  # Beyond this point — only what makes the answer incomplete or stale.
  if age.nil?
    puts '  ! схемы не сняты: про существование таблиц и колонок индекс не знает ничего (bin/xref schema)'
  elsif age > 24
    puts "  ! снимкам схем больше суток (#{age} ч): «таблицы нет» может быть ложью (bin/xref schema)"
  end
  if state['failed_sources'].to_i.positive?
    puts "  ! последнее снятие провалилось у #{state['failed_sources']} источников — ответ про них по старому снимку"
  end
  if state['generations'].to_i > 1
    puts "  ! дерево разобрано при #{state['generations']} разных поколениях схемы — часть ответов от старых входов (bin/xref code FULL=1)"
  end
  puts "  ! парсер SQL был недоступен: #{state['parserless']} запросов не разобрано (bundle install)" if state['parserless'].to_i.positive?
  puts "  ! #{state['scan_errors']} файлов не разобрались — это неполнота, а не отсутствие (bin/xref blind)" if state['scan_errors'].to_i.positive?
end

# Is a zero "nothing was found" or "nobody looked"? To be printed next to an
# empty answer.
# A view computed ONCE per command.
#
# The reports ask several questions of one and the same heavy view, and each of
# them recomputed it: `bin/xref texts` went to the list of orphaned keys four
# times and paid for it four times. A temporary table lives until the end of the
# connection, that is, exactly one command, and does not outlive somebody else's
# answers.
#
# The name is returned rather than substituted silently: a query must say
# explicitly that it reads a snapshot rather than the view.
def xref_snapshot(view)
  @xref_snapshots ||= {}
  @xref_snapshots[view] ||= begin
    name = "snap_#{view.sub(/\Av_/, '')}"
    conn = Xref::Store.conn
    conn.execute("create temp table #{name} as select * from #{view}")
    conn.execute("analyze #{name}")
    name
  end
end

def xref_zero_note(what = 'ответ')
  # Once per run: the explanation is the same while there can be four sections
  # with a zero.
  return if @xref_zero_shown

  @xref_zero_shown = true
  state = Xref::Store.freshness
  reasons = []
  reasons << 'парсер SQL был недоступен' if state['parserless'].to_i.positive?
  reasons << "#{state['scan_errors']} файлов не разобрались" if state['scan_errors'].to_i.positive?
  reasons << "разбор при #{state['generations']} поколениях схемы" if state['generations'].to_i > 1
  if reasons.empty?
    puts "   #{what} пустой при полном разборе #{state['files']} файлов — это отсутствие, а не неполнота"
  else
    puts "   #{what} пустой, но разбор НЕПОЛОН: #{reasons.join('; ')} — это может быть незнание"
  end
end

# An argument value is ALWAYS in UTF-8.
#
# `ENV` tags a string with the LOCALE's encoding rather than with the default,
# and the locale does not change after the process starts: with a broken locale
# a non-Latin pattern arrives as BINARY, and `format` with non-Latin text next to
# it dies on that — on 2026-10-09 `bin/xref find "<pattern>"` silently did not
# work that way. The re-exec in `bin/xref-run` closes this at the root, and this
# function covers the places where the re-exec could not happen (the system has
# no `C.UTF-8`) or where the task was called through `bin/rails`.
def xref_arg(key)
  value = ENV[key]
  value.nil? ? nil : Xref.utf8(value)
end

# The reliability of a finding class — as a line under the list of findings.
#
# This is the answer to a question the tool could not ask: how much to trust a
# NEW finding of this kind. Measured over 2026-10-08…09 — in a new layer false
# findings outnumber real ones two or three to one (137 broken examples → 7, 632
# broken links → 15, 22 missing translations → 6, 13 references to a
# non-existent column → 4) — and until that number is printed, every finding
# reads as equally weighty.
# Returns whether anything was printed: an EMPTY section is obliged to explain
# its zero through the journal rather than with the general caveat "this is an
# absence rather than incompleteness". A zero obtained by filtering out the
# verified is a third case, and before the journal it did not exist.
def xref_verdict_note(kind)
  row = Xref::Store.verdict_reliability(kind)
  return false if row.nil? || row['checked'].to_i.zero?

  parts = ["в этом разряде проверено #{row['checked']}"]
  if row['wrong'].to_i.positive?
    parts << "ложных #{row['wrong']} (#{row['wrong_share']} %) — проверенные ложными в ответы не идут"
  end
  parts << "устарел у #{row['stale']}: файл правили, находка вернулась" if row['stale'].to_i.positive?
  parts << "#{row['timeless']} без файла — такой вердикт не стареет никогда" if row['timeless'].to_i.positive?
  puts "   журнал проверок: #{parts.join('; ')}"
  puts "   что именно признано ложным и почему — bin/xref findings #{kind}" if row['wrong'].to_i.positive?
  true
end

# The observation window in words. Needed next to every "not touched in
# production": on its own that statement is unreadable — not touched in one day
# and not touched in a hundred days differ in everything while looking the same.
def xref_days(count)
  n = count.to_i
  return 'замера нет' if n.zero?

  n == 1 ? 'одни сутки' : "#{n} суток"
end

# The position of a hole in a query — in human terms. The order differs between
# reports while the names are shared: `xref:holes` and `xref:calls` are obliged
# to call the same thing the same way.
XREF_PLACES = {
  'table' => 'имя таблицы',   'glue' => 'приросло к имени',
  'in_list' => 'in (…)',      'condition' => 'целое условие',
  'order_by' => 'order by',   'group_by' => 'group by',
  'set' => 'set',             'select_list' => 'список select',
  'values' => 'values (…)',   'value' => 'значение справа от сравнения',
  'limit' => 'limit/offset',  'quoted' => "внутри кавычек '…'",
  'other' => 'прочее'
}.freeze

def xref_place(context)
  XREF_PLACES[context] || context
end

# The boundaries of the methods in a file:
# [{method:, class_name:, singleton:, from:, to:}].
# Needed where the question is asked in lines while the answer has to be in
# methods: an edit in a diff is line numbers, while "who calls this" is asked
# about a method.
def xref_defs_in(path)
  require 'prism'

  full = Xref.root.join(path)
  return [] unless File.file?(full)

  result = Prism.parse(File.read(full, encoding: 'UTF-8').scrub(''))
  return [] unless result.success?

  found = []
  stack = [[result.value, []]]
  while (node, scope = stack.pop)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      name = (node.constant_path.full_name rescue node.constant_path.slice) # rubocop:disable Style/RescueModifier
      node.compact_child_nodes.each { |child| stack << [child, scope + [name.to_s]] }
      next
    when Prism::DefNode
      found << { 'method' => node.name.to_s, 'class_name' => scope.join('::'),
                 'singleton' => !node.receiver.nil?,
                 'from' => node.location.start_line, 'to' => node.location.end_line }
    end
    node.compact_child_nodes.each { |child| stack << [child, scope] }
  end
  found
end

# The changed lines per file: { path => [line numbers of the new side] }.
# `-U0` so that the answer holds only the changes themselves, without three
# lines of context: otherwise a neighbouring method landed among the "touched".
def xref_changed_lines(ref)
  # The body of a diff is full of non-Latin comments; without a locale
  # `each_line` and `match` over it die, and `bin/xref changed` is what that
  # affects.
  out = Xref.utf8(`git -C #{Xref.root} diff -U0 #{ref} 2>/dev/null`)
  changed = {}
  path = nil
  out.each_line do |line|
    if line.start_with?('+++ b/')
      path = line[6..].to_s.strip
      path = nil if path == '/dev/null'
    elsif line.start_with?('@@') && path
      # @@ -12,3 +12,5 @@
      match = line.match(/\+(\d+)(?:,(\d+))?/)
      next if match.nil?

      start = match[1].to_i
      count = (match[2] || 1).to_i
      next if count.zero?

      (changed[path] ||= []).concat((start...(start + count)).to_a)
    end
  end
  changed
end

# How suitable a name is for a search at all.
#
# `g1` is a column of `big_users`, but it is also a node in the infrastructure
# and a favourite variable name. The report is obliged to say so out loud,
# otherwise the list of "candidates by text" reads as a list of places.
def show_ambiguity(conn, name)
  quoted = conn.quote(name)
  row = conn.select_one(<<~SQL.squish)
    select (select count(distinct table_name) from v_columns where column_name = #{quoted}) as in_tables,
           (select count(*) from v_tables where name = #{quoted}) as as_pg_table,
           (select count(*) from v_hb_tables where name = #{quoted}) as as_hb_table,
           (select count(distinct path) from code_refs where kind = 'token' and token = #{quoted}) as token_files
  SQL
  return if row.nil?

  parts = []
  parts << "колонка в #{row['in_tables']} таблицах" if row['in_tables'].to_i.positive?
  parts << 'ещё и имя таблицы' if row['as_pg_table'].to_i.positive?
  parts << 'ещё и таблица hbase' if row['as_hb_table'].to_i.positive?
  parts << "в тексте встречается в #{row['token_files']} файлах" if row['token_files'].to_i.positive?
  return if parts.empty?

  puts "   имя неоднозначно: #{parts.join(', ')}"
  return unless row['in_tables'].to_i > 3 || row['token_files'].to_i > 200

  puts '   поиск по тексту для такого имени бесполезен — смотрите разобранный SQL и AR'
end

# A list of files under one condition: how many in total and the first `limit`.
# The lines of the file themselves go with the answer "the file and the line
# numbers".
#
# Without them the answer sent you off to open the file: a line number says
# WHERE and says nothing about WHAT is there — while the decision is made by the
# second. The file is read once and only the lines already named; storing them in
# the index is pointless (that would be a second index, ageing separately from
# the first).
#
# Switched off with XREF_NO_SOURCE=1: in a narrow terminal long lines get in the
# way.
def xref_source_lines(path, wanted)
  return {} if ENV['XREF_NO_SOURCE'].present? || wanted.empty?

  full = Xref.root.join(path)
  return {} unless File.file?(full) && File.size(full) < 4_000_000

  # The line that opens a heredoc has no content of its own: the query starts on
  # the next line, and `select_one(<<~SQL)` in an answer says nothing. And a
  # heredoc here is the most common way of writing a query, so without this rule
  # half the answers would stay contentless. Two lines ahead are taken.
  need = wanted.flat_map { |line| [line, line + 1, line + 2] }.to_set
  rows = {}
  File.foreach(full, encoding: 'UTF-8').with_index(1) do |row, line|
    rows[line] = row.scrub('').strip if need.include?(line)
    break if line > need.max
  end

  wanted.to_h do |line|
    text = rows[line].to_s
    if text.match?(/<<[-~]?['"]?[A-Z]/)
      tail = [rows[line + 1], rows[line + 2]].compact.reject(&:empty?).first
      text = "#{text} ⤶ #{tail}" if tail
    end
    [line, text]
  end
rescue StandardError
  {}
end

# How many lines to show per file: more than three is no longer an answer, it is
# the file.
SOURCE_PER_FILE = 3

# Where this name is WRITTEN ABOUT. A separate section with a separate caption: a
# mention in a document is not an access to a table, and mixing them means
# declaring used whatever has merely been written about. But staying silent is
# not allowed either: a document is the only place that says WHY.
def show_doc_mentions(conn, name)
  rows = conn.select_all(<<~SQL.squish).to_a
    select doc, how, lines[1] as line, count from v_doc_name
    where name = #{conn.quote(name)} order by count desc, doc limit 10
  SQL
  total = conn.select_value("select count(distinct doc) from v_doc_name
                             where name = #{conn.quote(name)}").to_i
  puts
  puts "-- про это имя написано: #{total} документов (упоминание, а не обращение)"
  return if rows.empty?

  rows.each { |r| puts format('   %-58s %-18s стр. %s', r['doc'][0, 58], r['how'], r['line']) }
  puts "   … и ещё #{total - rows.size}" if total > rows.size
end

def show_usage(conn, where_sql, title, limit: 25, source: true)
  total = conn.select_value("select count(*) from code_refs where #{where_sql}").to_i
  puts
  puts "-- #{title}: #{total} файлов"
  if total.zero?
    xref_zero_note('раздел')
    return
  end

  conn.select_all(<<~SQL.squish).each do |r|
    select path, count, array_to_string(lines, ',') as lines
    from code_refs where #{where_sql} order by count desc, path limit #{limit}
  SQL
    puts format('   %-58s %3d  стр. %s', r['path'], r['count'], r['lines'])
    next unless source

    numbers = r['lines'].to_s.split(',').map(&:to_i).reject(&:zero?)
    text = xref_source_lines(r['path'], numbers.first(SOURCE_PER_FILE))
    numbers.first(SOURCE_PER_FILE).each do |line|
      puts format('        %5d  %s', line, text[line].to_s[0, 100]) if text[line].present?
    end
  end
  puts "   … и ещё #{total - limit}" if total > limit
end

namespace :xref do
  desc 'Создать базу индекса и накатить её схему'
  task init: :environment do
    Xref::Store.migrate!
    puts "индекс: #{Xref.store_url}"
    puts "источники в config/xref.yml: #{Xref.sources.keys.join(', ')}"
  end

  desc 'Снять схемы источников (SOURCES=prod-a,prod-b — только перечисленные)'
  task schema: :environment do
    Xref::Store.migrate!

    names = ENV['SOURCES'].presence&.split(',')&.map(&:strip) || Xref.sources.keys.map(&:to_s)
    failures = 0

    names.each do |name|
      cfg = Xref.source(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      print format('%-6s %-14s ', name, cfg[:transport])
      $stdout.flush

      begin
        src = Xref::SchemaSource.new(name)
        data = src.fetch
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        Xref::Store.write_snapshot(name, cfg, data, duration_ms: ms, warnings: src.warnings)

        puts format('PG %-8s %5d таблиц %5d колонок %5d индексов  %4d мс',
                    data['server_version'].to_s.split(' ').first,
                    Array(data['tables']).size, Array(data['columns']).size,
                    Array(data['indexes']).size, ms)
        # Rules and triggers are named separately: an insert into a table with a
        # rewrite rule may turn out to be an update, and that has to be known
        # straight away.
        extra = { 'правил' => data['rules'], 'триггеров' => data['triggers'],
                  'своих функций' => data['routines'], 'ограничений' => data['constraints'],
                  'последовательностей' => data['sequences'] }
                .filter_map { |label, list| "#{label} #{Array(list).size}" if Array(list).any? }
        puts "       #{extra.join(', ')}" if extra.any?
        src.warnings.each { |w| puts "       ! #{w}" }

        # The bodies of rules and functions are parsed right away: that is the
        # same SQL, only it lives in the database, and without it "nobody reads
        # this column" is sometimes a lie.
        if cfg[:kind].to_s == 'pg'
          db = Xref::DbSql.collect(name)
          if db && db[:refs].positive?
            note = "       разобрано тел: правил #{db[:rules]}, функций #{db[:routines]}, записей #{db[:refs]}"
            note += ", не разобрано тел #{db[:unparsed]} (не sql)" if db[:unparsed].positive?
            puts note
          end
        end
      rescue StandardError => e
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        failures += 1
        Xref::Store.write_failure(name, cfg, e.message, duration_ms: ms)
        puts "ОТКАЗ: #{e.message}"
      end
    end

    puts
    puts failures.zero? ? 'все источники сняты' : "источников не снято: #{failures}"
  end

  desc 'Отчёт о расхождениях схем между источниками'
  task drift: :environment do
    conn = Xref::Store.conn

    puts '== источники (последний удавшийся снимок) =='
    rows = Xref::Store.current_sources
    if rows.empty?
      puts 'снимков нет, начните с bin/xref schema'
      next
    end
    rows.each do |r|
      puts format('  %-6s PG %-8s %-16s %s', r['source'],
                  r['server_version'].to_s.split(' ').first, r['database_name'], r['taken_at'])
    end

    total = conn.select_value('select count(*) from v_table_presence').to_i
    everywhere = conn.select_value('select count(*) from v_table_presence where cardinality(missing_in) = 0').to_i
    puts
    puts "== таблицы: всего различных #{total}, есть во всех источниках #{everywhere} =="

    conn.select_all(<<~SQL.squish).each do |g|
      select array_to_string(missing_in, ',') as missing, count(*) as cnt,
             array_to_string((array_agg(name order by name))[1:8], ', ') as sample
      from v_table_drift group by missing_in order by count(*) desc
    SQL
      puts format('  нет в [%s]: %d', g['missing'], g['cnt'])
      puts "      #{g['sample']}#{g['cnt'].to_i > 8 ? ', …' : ''}"
    end

    puts
    puts '== колонки (только у таблиц, которые есть во всех источниках) =='
    drift = conn.select_all(<<~SQL.squish).to_a
      select table_name, column_name, array_to_string(present_in, ',') as present,
             array_to_string(missing_in, ',') as missing
      from v_column_drift order by table_name, column_name
    SQL
    if drift.empty?
      puts '  расхождений нет'
    else
      drift.first(60).each do |r|
        puts format('  %-40s есть в [%s], нет в [%s]', "#{r['table_name']}.#{r['column_name']}", r['present'], r['missing'])
      end
      puts "  … всего #{drift.size}" if drift.size > 60
    end

    puts
    puts '== один столбец, разные типы =='
    types = conn.select_all(<<~SQL.squish).to_a
      select table_name, column_name, array_to_string(types_by_source, ', ') as by_source
      from v_type_drift order by table_name, column_name
    SQL
    if types.empty?
      puts '  расхождений нет'
    else
      types.each { |r| puts format('  %-40s %s', "#{r['table_name']}.#{r['column_name']}", r['by_source']) }
    end
  end

  desc 'Снять факты из запущенного приложения: модели, связи, роуты, контроллеры'
  task app: :environment do
    Xref::Store.migrate!

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Xref::RailsFacts.load!
    models = Xref::RailsFacts.models
    associations = Xref::RailsFacts.associations
    routes = Xref::RailsFacts.routes
    controllers = Xref::RailsFacts.controllers
    jobs = Xref::RailsFacts.jobs
    constants = Xref::RailsFacts.constants
    Xref::Store.write_rails_facts(models: models, associations: associations,
                                  routes: routes, controllers: controllers,
                                  jobs: jobs, constants: constants)

    puts format('модели %d, связи %d, роуты %d, контроллеры %d, работы %d, константы %d — за %.1f с',
                models.size, associations.size, routes.size, controllers.size,
                jobs.size, constants.size,
                Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

    nameless = models.count { |m| m[:path].blank? }
    puts "  ! у #{nameless} моделей не нашёлся файл" if nameless.positive?

    conn = Xref::Store.conn
    # Our models are the ones under ApplicationRecord. Other subsystems and the
    # framework keep their own abstract base classes and their own databases.
    own = "(m.base is null or m.base in ('ApplicationRecord', 'ActiveRecord::Base'))"

    orphan = conn.select_all(<<~SQL.squish).to_a
      select m.class_name, m.table_name
      from app_models m
      left join v_table_presence tp on tp.name = m.table_name
      where m.table_name is not null and tp.name is null and #{own}
      order by m.class_name
    SQL
    if orphan.any?
      puts "  ! модели, чьей таблицы нет ни в одном источнике: #{orphan.size}"
      orphan.first(15).each { |r| puts "      #{r['class_name']} -> #{r['table_name']}" }
    end

    partial = conn.select_all(<<~SQL.squish).to_a
      select m.class_name, m.table_name, array_to_string(tp.missing_in, ',') as missing
      from app_models m
      join v_table_presence tp on tp.name = m.table_name
      where cardinality(tp.missing_in) > 0
      order by m.class_name
    SQL
    if partial.any?
      puts "  ! модели, чья таблица есть не везде: #{partial.size}"
      partial.each { |r| puts format('      %-28s %-26s нет в [%s]', r['class_name'], r['table_name'], r['missing']) }
    end
  end

  desc 'Тексты: ключ зовут, а перевода нет — и наоборот (bin/xref texts)'
  task texts: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    rows = Xref::Locales.collect
    Xref::Store.write_locale_keys(rows)
    langs = conn.select_values('select lang from locale_keys group by lang order by count(*) desc')
    puts format('== хранилище: %d ключей на %d языках из %d файлов (читано ПОМИМО I18n) ==',
                conn.select_value('select count(distinct key) from locale_keys').to_i,
                langs.size, conn.select_value('select count(distinct file) from locale_keys').to_i)

    # A snapshot: the summary over the accesses is asked for five times here,
    # and each time it was a decomposition of every key of the store into
    # prefixes.
    usage = xref_snapshot('v_i18n_usage')
    # WHICH LANGUAGES MUST BE THERE IS A HABIT OF THE TREE (`idioms.main_locales`),
    # not a property of the engine: these are the ones a fallback hides.
    main = Array(Xref.idioms[:main_locales]).map(&:to_s)
    gaps = main.map { |lang| "count(*) filter (where in_store and not (#{conn.quote(lang)} = any(langs_list)))::int as no_#{lang}" }
    used = conn.select_one(<<~SQL.squish)
      select count(*)::int as keys, coalesce(sum(files), 0)::int as places,
             count(*) filter (where not in_store and not has_default
                                and #{Xref::Verdicts.filter_sql('locale')})::int as missing,
             count(*) filter (where not in_store and has_default)::int as missing_ok
             #{gaps.empty? ? '' : ", #{gaps.join(', ')}"}
      from #{usage}
    SQL
    puts format('   код зовёт %d ключей в %d местах', used['keys'], used['places'])

    # The main finding: the key is not in the store at all. A human will see
    # "translation missing" — or, if the key is assembled, will see nothing.
    # "Looks like" turns a finding into a ready fix: every verified case turned
    # out to be a miss of the NAMESPACE — `general.refresh` instead of
    # `home.refresh`, `online` instead of `theme_desktop.online`. The lookup goes
    # by the last segment of the key.
    # The last segment of a key is computed ONCE for the whole store rather than
    # for each finding: previously this query decomposed all 102,648 keys for
    # each of the thirty rows of the answer and cost three seconds on its own.
    missing = conn.select_all(<<~SQL.squish).to_a
      with leaf as (
        select distinct split_part(key, '.', array_length(string_to_array(key, '.'), 1)) as leaf, key
        from locale_keys where key <> ''
      ),
      want as (
        select u.key, u.files, u.paths,
               split_part(u.key, '.', array_length(string_to_array(u.key, '.'), 1)) as leaf
        from #{usage} u where not u.in_store and not u.has_default
          and #{Xref::Verdicts.filter_sql('locale')}
        order by u.files desc, u.key limit 30
      )
      select w.key, w.files, array_to_string(w.paths[1:2], ', ') as sample,
             (select string_agg(distinct l.key, ', ' order by l.key)
              from leaf l where l.leaf = w.leaf and l.key <> w.key) as looks_like
      from want w order by w.files desc, w.key
    SQL
    puts
    puts "== ключ зовут из кода, а в хранилище его НЕТ: #{used['missing']} =="
    puts format('   (ещё %d таких ключей зовут с запасным текстом — `default:` — и человек', used['missing_ok'])
    puts '    увидит его, а не «translation missing»: в счёт пропусков они не идут)' if used['missing_ok'].to_i.positive?
    puts '   человек увидит «translation missing» — ни запасные языки, ни fallback не помогут'
    missing.each do |r|
      puts format('  %-46s в %d местах  %s', r['key'][0, 46], r['files'], r['sample'].to_s[0, 40])
      puts format('      есть как: %s', r['looks_like'].to_s[0, 86]) if r['looks_like'].present?
    end
    xref_verdict_note('locale')

    # A zero here is an answer, and it has to be printed in words: the main
    # languages are exactly what cover the others through fallbacks, and if one
    # of them is missing a human sees a foreign language or the key itself.
    if main.all? { |lang| used["no_#{lang}"].to_i.zero? }
      puts
      puts "== у всех зовущихся ключей есть #{main.join(' и ')} — пропусков нет ==""
      # The per-key summary is computed once: previously there were two passes
      # over 102,648 rows here counting distinct languages, 1.3 s each.
      by_key = conn.select_one(<<~SQL.squish)
        select #{main.map { |lang| "count(*) filter (where not (#{conn.quote(lang)} = any(langs)))::int as no_#{lang}" }.join(', ')}
        from (select key, array_agg(distinct lang) as langs from locale_keys group by key) q
      SQL
      puts format('   (в хранилище при этом %s, но их не зовёт никто)',
                  main.map { |lang| "#{by_key["no_#{lang}"]} ключей без #{lang}" }.join(' и '))
    end

    # The untranslated hidden by the fallbacks: the key exists while the
    # required language does not. `I18n.t` answers such a case in English and
    # says nothing.
    main.each do |lang|
      gap = conn.select_all(<<~SQL.squish).to_a
        select key, files from #{usage}
        where in_store and not (#{conn.quote(lang)} = any(langs_list)) order by files desc, key limit 12
      SQL
      next if gap.empty?

      total = used["no_#{lang}"]
      puts
      puts "== ключ есть, а перевода на #{lang} нет: #{total} =="
      puts '   запасные языки это прячут: приедет другой язык, и молча'
      gap.each { |r| puts format('  %-56s в %d местах', r['key'][0, 56], r['files']) }
    end

    # The other side: a text gets translated into eighteen languages and there is
    # nothing to show it.
    # The list of orphans is asked for four times here; it is computed once.
    # An assembled key is not "something unknown". The pattern
    # `user_notifs.L$1` is "one of user_notifs.Lmen, user_notifs.Lwomen", and
    # the store knows the answer: of 137 patterns 95 resolve that way. And a
    # pattern that matched NOT A SINGLE key is a finding the index did not have
    # before 2026-10-09: that is exactly how `month.m$1` was found while the
    # store holds `months.m1..m12`.
    patterns = conn.select_one(<<~SQL.squish)
      select count(*)::int as total,
             (select count(distinct path) from code_refs where kind = 'i18n_dynamic')::int as places,
             count(*) filter (where verdict like 'один из%')::int as narrow,
             count(*) filter (where verdict like 'широкий%')::int as wide,
             count(*) filter (where verdict = 'НИ ОДНОГО КЛЮЧА')::int as empty,
             count(*) filter (where verdict = 'приставка слишком короткая')::int as short
      from v_i18n_pattern
    SQL
    puts
    puts "== ключ собран на лету: #{patterns['total']} узоров в #{patterns['places']} файлах =="
    puts format('   хранилище отвечает за %d из них (ключей не больше двадцати), широких %d, ' \
                'приставка короче четырёх знаков у %d', patterns['narrow'], patterns['wide'], patterns['short'])
    empty = conn.select_all(<<~SQL.squish).to_a
      select pattern, files, array_to_string(paths[1:2], ', ') as sample, prefix
      from v_i18n_pattern
      where verdict = 'НИ ОДНОГО КЛЮЧА' and #{Xref::Verdicts.filter_sql('locale_pattern')}
      order by files desc, pattern
    SQL
    if empty.any?
      puts "   !! узор НЕ СОВПАЛ ни с одним ключом хранилища: #{empty.size} —"
      puts '      человек увидит «translation missing», и статически это видно только так'
      empty.each { |r| puts format('      %-34s %s', r['pattern'][0, 34], r['sample'].to_s[0, 60]) }
    end
    xref_verdict_note('locale_pattern')
    narrow = conn.select_all(<<~SQL.squish).to_a
      select pattern, verdict, key_list from v_i18n_pattern
      where verdict like 'один из%' order by keys, pattern limit 12
    SQL
    if narrow.any?
      puts '   примеры разрешённых узоров:'
      narrow.each { |r| puts format('      %-30s %-12s %s', r['pattern'][0, 30], r['verdict'], r['key_list'].to_s[0, 62]) }
    end

    snap = xref_snapshot('v_locale_orphan')
    orphan = conn.select_value("select count(*) from #{snap}").to_i
    dynamic = conn.select_value("select count(*) from code_refs where kind = 'i18n_dynamic'").to_i
    puts
    puts "== ключ есть в хранилище, а в коде его не зовёт никто: #{orphan} =="
    puts "   уже вычтены ключи под пространствами, которые зовут собранным ключом"
    puts "   (#{dynamic} таких мест в дереве; узоры короче четырёх букв в зачёт не идут —"
    puts '   узор `$1` совпадает с любым ключом и объясняет сразу всё, то есть ничего)'
    # BY FILES rather than by keys: nobody will read three thousand names, while
    # "this file holds 1,370 unnecessary keys" is already a decision.
    conn.select_all(<<~SQL.squish).to_a.each do |r|
      select f.file, count(*)::int as n from #{snap} o
      cross join lateral unnest(o.files) as f(file)
      where f.file like 'config/site_locales/%'
      group by 1 order by 2 desc limit 8
    SQL
      puts format('  %-52s %d ключей', r['file'], r['n'])
    end
    legacy = conn.select_value(<<~SQL.squish).to_i
      select count(distinct o.key) from #{snap} o
      where exists (select 1 from locale_keys k where k.key = o.key and k.file like 'config/locales/%')
    SQL
    # The number of languages is taken from THE DATA rather than from memory: in
    # a second project this trailing line claimed "in 18 languages" about a tree
    # with two.
    langs_here = conn.select_value("select count(distinct lang) from locale_keys
                                    where file like 'config/locales/%'").to_i
    puts format('  %-52s %d ключей (общий legacy на %d языках)',
                'config/locales/*.yml', legacy, langs_here)
  end

  desc 'Ключи окружения: код читает, а в среде нет — и наоборот (bin/xref env)'
  task env: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    (Xref.config[:run_places] || {}).each do |place, cfg|
      print format('%-5s %-6s имена ключей ... ', place, cfg[:ssh_host])
      $stdout.flush
      begin
        names = Xref::EnvKeys.collect(cfg[:ssh_host], cfg[:container_match])
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message[0, 90]}"
        next
      end
      puts "#{names.size} (значения не читаются)"
      Xref::Store.write_env_keys(place, names)
    end

    # KEYS DECLARED BY A FILE, not by a live container. A project without ssh to
    # anything still declares its settings somewhere — `.env.example`, a sample
    # compose file — and that declaration is as much an answer to "is this key
    # known" as a container's environment. Without it a tree with no remote
    # places got "ни одной среды не опросили" and the whole report stayed silent.
    #
    #   env_declared:
    #     example: .env.example
    #
    # Only NAMES are read here as everywhere else: everything to the right of the
    # first `=` is dropped before anything is remembered.
    (Xref.config[:env_declared] || {}).each do |place, path|
      file = Xref.root.join(path.to_s)
      unless file.file?
        puts format('%-5s %-6s объявленных ключей НЕТ: файла %s нет', place, '-', path)
        next
      end

      names = Xref.utf8(file.read).lines.filter_map do |line|
        name = line[/\A\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=/, 1]
        name unless name.nil?
      end.uniq
      puts format('%-5s %-6s объявлено ключей: %d (из %s, значения не читаются)',
                  place, 'файл', names.size, path)
      Xref::Store.write_env_keys(place, names)
    end

    places = conn.select_values('select distinct place from env_keys order by 1')
    if places.empty?
      puts 'ни одной среды не опросили и ни одного файла с объявленными ключами'
      next
    end

    # The main finding: the code reads a key the environment does not define. The
    # `nil` arrives silently — no error, no log line.
    #
    # VARIABLES THE SYSTEM SETS ARE EXEMPT (`idioms.standard_env`): `PATH`,
    # `HOME`, `LANG`, `RAILS_ENV` are given by the shell, the container or the
    # framework, and a container that does not export one of them into the
    # snapshot does not mean the code is reading a hole. Until this condition
    # existed the list was a list with no consumer — the names were configured
    # and nothing applied them, which is the same defect as a setting with no
    # effect (III.4). The count of what was exempted is printed, so the
    # exemption cannot quietly swallow a real finding.
    standard = Array(Xref.idioms[:standard_env]).map(&:to_s)
    standard_list = standard.map { |n| conn.quote(n) }.join(', ')
    exempt_sql = standard.empty? ? '' : "and name <> all (array[#{standard_list}]::text[])"
    missing = conn.select_all(<<~SQL.squish).to_a
      select name, app_files, task_files, array_to_string(paths[1:3], ', ') as sample
      from v_env_usage
      where app_files > 0 and cardinality(set_in) = 0 and not has_default and not is_flag
        #{exempt_sql}
      order by app_files desc, name limit 40
    SQL
    exempted = conn.select_value(<<~SQL.squish).to_i
      select count(*)::int from v_env_usage
      where app_files > 0 and cardinality(set_in) = 0 and not has_default and not is_flag
        #{standard.empty? ? 'and false' : "and name = any (array[#{standard_list}]::text[])"}
    SQL
    softened = conn.select_one(<<~SQL.squish)
      select count(*) filter (where has_default)::int as with_default,
             count(*) filter (where is_flag and not has_default)::int as flags
      from v_env_usage where app_files > 0 and cardinality(set_in) = 0
    SQL
    puts
    puts "== БОЕВОЙ КОД читает ключ, которого нет ни в одной среде, БЕЗ запасного значения: #{missing.size} =="
    puts '   nil приходит молча: ни ошибки, ни строки в логе'
    missing.each do |r|
      puts format('  %-34s в %d файлах%s  %s', r['name'], r['app_files'],
                  r['task_files'].to_i.positive? ? " (+#{r['task_files']} в задачах)" : '',
                  r['sample'].to_s[0, 58])
    end

    puts
    puts format('   (ещё %d не заданы, но у чтения есть запасное значение, и %d читаются как',
                softened['with_default'], softened['flags'])
    puts '    ПРИЗНАК — `if ENV[…]`, где пустое значение законно и значит «выключено»)'
    if exempted.positive?
      puts format('   (и ещё %d не названы потому, что их ставит система — список idioms.standard_env)', exempted)
    end

    # A key read ONLY by shell scripts. While `.sh` went unparsed there were no
    # such keys in the report at all — in no class: the environment report stayed
    # silent about 133 names, and about some of them claimed "not read in the
    # code", which was a plain untruth.
    only_shell = conn.select_all(<<~SQL.squish).to_a
      select name, sh_files, array_to_string(set_in, ',') as set_in,
             array_to_string(paths[1:2], ', ') as sample
      from v_env_usage
      where app_files = 0 and task_files = 0 and sh_files > 0
      order by sh_files desc, name limit 20
    SQL
    total_shell = conn.select_value(<<~SQL.squish).to_i
      select count(*) from v_env_usage where app_files = 0 and task_files = 0 and sh_files > 0
    SQL
    if only_shell.any?
      puts
      puts "== ключ читают ТОЛЬКО скрипты оболочки: #{total_shell} =="
      puts '   до разбора .sh этих имён в отчёте не было ни в одном разряде'
      only_shell.each do |r|
        puts format('  %-34s в %d скриптах  %s  %s', r['name'], r['sh_files'],
                    r['set_in'].to_s.empty? ? 'в средах НЕ задан' : "задан в [#{r['set_in']}]",
                    r['sample'].to_s[0, 44])
      end
    end

    only_tasks = conn.select_value(<<~SQL.squish).to_i
      select count(*) from v_env_usage
      where app_files = 0 and task_files > 0 and cardinality(set_in) = 0
    SQL
    if only_tasks.positive?
      puts
      puts "   (ещё #{only_tasks} ключей читают только rake-задачи и скрипты: это их аргументы"
      puts '    командной строки, в среде их задавать и не надо)'
    end

    # Defined not everywhere: the behaviour of the environments drifts apart, and
    # that has happened already.
    partial = conn.select_all(<<~SQL.squish).to_a
      select name, files, array_to_string(set_in, ',') as set_in
      from v_env_usage
      where app_files > 0 and cardinality(set_in) > 0 and cardinality(set_in) < #{places.size}
      order by name limit 30
    SQL
    if partial.any?
      puts
      puts "== ключ задан НЕ ВО ВСЕХ средах: #{partial.size} =="
      partial.each { |r| puts format('  %-34s задан только в [%s]', r['name'], r['set_in']) }
    end

    # The other side: the key is defined while nothing in the code reads it.
    dead = conn.select_all(<<~SQL.squish).to_a
      select k.name, string_agg(distinct k.place, ',' order by k.place) as places
      from env_keys k
      where not exists (select 1 from code_refs r where r.kind = 'env_key' and r.token = k.name)
      group by 1 order by 1
    SQL
    next if dead.empty?

    puts
    puts "== ключ задан, а в коде его не читает никто: #{dead.size} =="
    puts '   часть из них читает не ruby (nginx, оболочки, сам docker) — это шорт-лист на разбор'
    dead.each_slice(4) { |slice| puts "  #{slice.map { |r| r['name'] }.join(', ')}" }
  end

  desc 'Миграции по средам: применено, не применено, лишнее (bin/xref migrations)'
  task migrations: :environment do
    Xref::Store.migrate!
    repo = Xref::Migrations.in_repo
    applied = {}
    Xref.config[:sources].each do |name, cfg|
      next unless %w[pg].include?(cfg[:kind].to_s)
      next if cfg[:transport].to_s == 'structure_sql'

      print format('%-5s ... ', name)
      $stdout.flush
      versions = Xref::Migrations.applied(name)
      if versions.nil?
        puts 'ОТКАЗ: спросить не удалось'
        next
      end
      puts "применено #{versions.size}"
      applied[name.to_s] = versions
      Xref::Store.write_migrations(name, versions)
    end

    if applied.empty?
      puts 'ни одной среды не опросили — проверьте доступ'
      next
    end

    puts
    puts "== в дереве миграций: #{repo.size} (только метки времени) =="
    report = Xref::Migrations.compare(applied, repo)
    report.each do |source, data|
      puts format('  %-5s применено %3d (+%d старых номеров), не применено %d, лишних %d',
                  source, data[:applied], data[:legacy], data[:missing].size, data[:extra].size)
    end

    # The main finding: the migration exists in the tree while the environment
    # does not have it. That is usually discovered halfway through a deploy — let
    # it be discovered in advance.
    report.each do |source, data|
      next if data[:missing].empty?

      puts
      puts "== НЕ ПРИМЕНЕНО в #{source}: #{data[:missing].size} =="
      data[:missing].last(10).each do |version|
        file = Dir["db/migrate/#{version}_*.rb"].first
        puts format('  %-16s %s', version, file ? File.basename(file) : '—')
      end
    end

    report.each do |source, data|
      next if data[:extra].empty?

      puts
      puts "== применено в #{source}, а файла в дереве НЕТ: #{data[:extra].size} =="
      puts '   файл удалён или миграция пришла из другой ветки'
      data[:extra].last(10).each { |version| puts "  #{version}" }
    end

    # A divergence between environments is the cause of a schema drift.
    pairs = applied.keys.combination(2).to_a
    diffs = pairs.filter_map do |a, b|
      only_a = (applied[a] - applied[b]).select { |v| v.match?(Xref::Migrations::TIMESTAMP) }
      only_b = (applied[b] - applied[a]).select { |v| v.match?(Xref::Migrations::TIMESTAMP) }
      [[a, b], only_a, only_b] if only_a.any? || only_b.any?
    end
    next if diffs.empty?

    puts
    puts '== среды разошлись между собой =='
    diffs.each do |(a, b), only_a, only_b|
      puts format('  %s против %s: только в %s %d, только в %s %d', a, b, a, only_a.size, b, only_b.size)
      (only_a.last(3) + only_b.last(3)).each { |v| puts "     #{v}" }
    end
  end

  desc 'Выполненные запросы из статистики базы (pg_profile): bin/xref sql profile [DAYS=30]'
  task sql_profile: :environment do
    Xref::Store.migrate!
    cfg = Xref.config[:sql_profile] || {}
    if cfg.empty?
      puts 'раздела sql_profile в config/xref.yml нет — сбор из статистики базы не настроен'
      next
    end

    days = (ENV['DAYS'].presence || Xref::SqlProfile::DEFAULT_DAYS).to_i
    known = Xref::Store.known_names
    wanted = ENV['PLACES'].to_s.split(',').map(&:strip).reject(&:empty?)

    cfg.each do |place, place_cfg|
      next if wanted.any? && !wanted.include?(place.to_s)

      print format('%-5s pg_profile за %d суток ... ', place, days)
      $stdout.flush
      begin
        found = Xref::SqlProfile.collect(place, place_cfg, days: days)
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message}"
        next
      end
      puts "узоров #{found.size}, суток #{found.map { |row| row[:day] }.uniq.size}"
      # The parse of the skeletons is the same as for the logs: tables, columns,
      # write targets.
      Xref::Store.write_sql_runtime(place, Xref::SqlRuntime.analyze(found, known: known))
    end

    conn = Xref::Store.conn
    window = conn.select_one(<<~SQL.squish)
      select count(distinct day)::int as days, min(day) as a, max(day) as b,
             count(*)::int as rows, coalesce(sum(hits), 0)::bigint as hits
      from sql_runtime where host = 'pg_profile'
    SQL
    puts
    puts format('== из статистики базы: %s суток (%s — %s), узор-дней %s, выполнений %s ==',
                window['days'], window['a'], window['b'], window['rows'], window['hits'])
    puts '   значения не покидали узел: нормализация идёт там, наружу едет узор и счётчик'
    logs = conn.select_one("select count(distinct day)::int as days, min(day) as a, max(day) as b
                            from sql_runtime where host <> 'pg_profile'")
    if logs['days'].to_i.positive?
      puts format('   для сравнения, по логам пумы: %s суток (%s — %s)', logs['days'], logs['a'], logs['b'])
    end
  end

  desc 'Выполненные запросы из боевых логов: bin/xref sql [DATE=2026-10-07] [PLACES=prod-a]'
  task sql: :environment do
    Xref::Store.migrate!
    cfg = Xref.config[:view_logs] || {}
    day = (ENV['DATE'].presence ? Date.parse(ENV['DATE']) : Date.today)
    wanted = ENV['PLACES'].to_s.split(',').map(&:strip).reject(&:empty?)
    known = Xref::Store.known_names

    (cfg[:places] || {}).each do |place, place_cfg|
      next if wanted.any? && !wanted.include?(place.to_s)

      rows = []
      Array(place_cfg[:hosts]).each do |host|
        print format('%-5s %-6s логи за %s ... ', place, host, day)
        $stdout.flush
        begin
          found = Xref::SqlRuntime.collect(host, place_cfg[:glob], day: day)
        rescue StandardError => e
          puts "ОТКАЗ: #{e.message}"
          next
        end
        puts "узоров #{found.size}"
        rows.concat(Xref::SqlRuntime.analyze(found, known: known))
      end
      # An empty answer does not erase what was collected: see
      # write_sql_runtime.
      Xref::Store.write_sql_runtime(place, rows)
    end

    conn = Xref::Store.conn
    puts
    # The numbers OF THE DAY and the numbers OF THE WINDOW, separately. In one
    # line they came together wrongly: the skeletons were counted for a single
    # day while the tables and columns for everything accumulated, and the line
    # read as "in one day that many tables were seen".
    totals = conn.select_one(<<~SQL.squish)
      select count(*)::int as skeletons, coalesce(sum(hits), 0)::bigint as hits,
             count(*) filter (where not parsed)::int as unparsed
      from sql_runtime where day = #{conn.quote(day.to_s)}
    SQL
    puts format('== за %s: узоров %s, выполнений %s, не разобрано %s ==',
                day, totals['skeletons'], totals['hits'], totals['unparsed'])

    # The window is the main number of this report, and it grows only through
    # repeated collection: every run adds a day, the previous ones are not
    # erased. Everything the index says with the words "not touched in
    # production" is exactly as strong as that window is wide.
    window = conn.select_one('select * from v_runtime_window')
    tables = conn.select_value('select count(distinct table_name) from v_runtime_table').to_i
    columns = conn.select_value('select count(distinct column_name) from v_runtime_column').to_i
    puts format('   окно наблюдения: %s (%s…%s), узоров %s, таблиц %d, колонок %d',
                xref_days(window['days']), window['first_day'], window['last_day'],
                window['skeletons'], tables, columns)
    if window['days'].to_i < 2
      puts '   окно в одни сутки — самое слабое место этого уровня доказательства:'
      puts '   редкий крон в него не попадает вовсе. Расширяется только повторным сбором'
    end

    # THE MAIN REASON this is collected: a table name the code assembles by
    # interpolation is known to the log already resolved.
    resolved = conn.select_all(<<~SQL.squish).to_a
      select g.token as stem, string_agg(distinct rt.table_name, ', ' order by rt.table_name) as seen,
             count(distinct rt.table_name)::int as n
      from code_refs g
      join v_runtime_table rt on rt.table_name like g.token || '%' and rt.table_name <> g.token
      where g.kind = 'pg_table_guess'
      group by 1 order by 3 desc, 1 limit 20
    SQL
    if resolved.any?
      puts
      puts "== имя собрано в коде, а в бою это были такие таблицы: #{resolved.size} узоров =="
      resolved.each { |r| puts format('  %-28s %s', "#{r['stem']}…", r['seen'][0, 90]) }
    end

    # A table touched in one data centre only. Statically that cannot be
    # learned: the choice is made by the environment (`ENV['DATA_CENTRE']`) and the
    # code holds a ternary. For questions about replication and consistency this
    # is the key fact.
    single = conn.select_all(<<~SQL.squish).to_a
      select table_name, string_agg(place, ',' order by place) as places, coalesce(sum(hits), 0)::bigint as hits
      from v_runtime_table group by 1 having count(distinct place) = 1
      order by 3 desc limit 12
    SQL
    if single.any? && conn.select_value('select count(distinct place) from sql_runtime').to_i > 1
      puts
      puts "== трогают только в одном ДЦ: #{single.size} таблиц =="
      puts '   выбор часто делает окружение, и статически это тернарник без ответа'
      single.each { |r| puts format('  %-36s только %-5s %9s выполнений', r['table_name'], r['places'], r['hits']) }
    end

    unknown = conn.select_all('select table_name, place, hits, queries from v_runtime_unknown_table
                               order by hits desc limit 15').to_a
    if unknown.any?
      puts
      puts "== в бою трогали таблицу, которой НЕ называет ни один разобранный запрос: #{unknown.size} =="
      puts '   это либо разрешённое имя из интерполяции, либо работа не этого приложения'
      unknown.each { |r| puts format('  %-34s %-5s %9s выполнений в %d запросах', r['table_name'], r['place'], r['hits'], r['queries']) }
    end
  end

  desc 'Заполненность колонок живыми данными: bin/xref fill TABLE=legacy_users[,big_users]'
  task fill: :environment do
    Xref::Store.migrate!
    tables = xref_arg('TABLE').to_s.split(',').map(&:strip).reject(&:empty?)
    abort 'нужен TABLE=<таблица>[,<таблица>]' if tables.empty?

    cfg = Xref.config[:fill] || {}
    # There can be no default BY ENVIRONMENT NAME here: this is a full read of a
    # production table, and "nobody said which, so let us go to the first source
    # at hand" will one day read the wrong one. The source is named by the
    # configuration or by the caller.
    sources = (ENV['SOURCES'].presence || cfg[:sources].presence).to_s.split(',').map(&:strip)
    abort 'не задан источник замера: SOURCES=<источник> или раздел fill.sources в config/xref.yml' if sources.empty?

    sources.each do |source|
      print format('%-5s таблиц %d, сплошной проход ... ', source, tables.size)
      $stdout.flush
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        stats = Xref::DataFacts.collect(source, tables: tables)
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message}"
        next
      end
      puts format('колонок %d в %d таблицах за %.1f с', stats[:columns], stats[:tables],
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      stats[:skipped].each { |note| puts "   ! #{note}" }

      print format('%-5s сканирования индексов ... ', source)
      $stdout.flush
      begin
        puts "индексов #{Xref::DataFacts.index_usage(source)}"
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message}"
      end
    end

    conn = Xref::Store.conn
    rows = conn.select_all(<<~SQL.squish).to_a
      select source, table_name, column_name, verdict, filled, off_default, filled_recent, share
      from v_column_fill where table_name in (#{tables.map { |t| conn.quote(t) }.join(',')})
        and verdict <> 'заполняется'
      order by source, table_name, verdict, column_name
    SQL
    next if rows.empty?

    puts
    puts '== что замер говорит против кода =='
    rows.group_by { |row| [row['source'], row['table_name']] }.each do |(source, table), list|
      puts "   #{source} #{table}:"
      list.each do |row|
        puts format('     %-30s %-24s заполнено %s%s%s', row['column_name'], row['verdict'],
                    row['filled'],
                    row['off_default'] ? ", не по умолчанию #{row['off_default']}" : '',
                    row['filled_recent'] ? ", у новых #{row['filled_recent']}" : '')
      end
    end
  end

  desc 'Собрать ключи внутри jsonb-полей выборкой из данных'
  task json: :environment do
    Xref::Store.migrate!

    cfg = Xref.config[:json_sampling] || {}
    sources = Array(cfg[:sources].presence || cfg[:source]).map(&:to_s)
    abort 'не задан источник выборки: раздел json_sampling.sources в config/xref.yml' if sources.empty?
    rows = (cfg[:rows] || 5000).to_i

    sources.each do |source|
      columns = Xref::JsonKeys.jsonb_columns(source)
      if columns.empty?
        puts "#{source}: колонок jsonb не найдено — нужен свежий bin/xref schema"
        next
      end

      print format('%-5s колонок jsonb %3d, выборка по %d строк ... ', source, columns.size, rows)
      $stdout.flush

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        keys = Xref::JsonKeys.collect(source, rows: rows, statement_timeout: cfg[:statement_timeout] || '20s')
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message}"
        next
      end
      Xref::Store.write_json_keys(source, keys)

      filled = keys.map { |k| [k[:table_name], k[:column_name]] }.uniq.size
      puts format('ключей %d в %d полях, пустых полей %d — за %.1f с',
                  keys.size, filled, columns.size - filled,
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    conn = Xref::Store.conn
    # A column that yielded no keys at all refutes nothing: there was simply
    # nothing to sample there. Mixing those two cases means passing an empty
    # table off as a typo in the code.
    missing = conn.select_all(<<~SQL.squish).to_a
      select g.table_name, g.column_name, g.key, g.used_in,
             exists (select 1 from json_keys k
                     where k.table_name = g.table_name and k.column_name = g.column_name) as sampled
      from v_json_key_gap g
      where g.hits is null
      order by sampled desc, g.table_name, g.column_name, g.key
    SQL
    next if missing.empty?

    real, unsampled = missing.partition { |r| r['sampled'] == true || r['sampled'] == 't' }

    if real.any?
      puts
      puts '== код читает ключ, которого в данных нет =='
      real.each { |r| puts format('  %-46s %s', "#{r['table_name']}.#{r['column_name']}.#{r['key']}", r['used_in']) }
    end

    # A key met ONLY in a semi-production environment is not a production fact:
    # such an environment collects the traces of experiments. The name of the
    # environment comes from the configuration: a hard-coded name lies silently
    # the moment the environment is renamed or ceases to exist.
    semi_name = (Xref.config[:json_sampling] || {})[:semi_production].to_s
    semi = if semi_name.empty?
             []
           else
             conn.select_all(<<~SQL.squish).to_a
               select table_name, column_name, key, sum(hits) as hits
               from json_keys group by table_name, column_name, key
               having array_agg(distinct source) = array[#{conn.quote(semi_name)}]
               order by sum(hits) desc, table_name, column_name, key
             SQL
           end
    if semi.any?
      puts
      puts "== ключи, встреченные ТОЛЬКО в #{semi_name} (#{semi.size}) — следы опытов, не боевые данные =="
      semi.first(12).each { |r| puts format('  %-46s %s строк', "#{r['table_name']}.#{r['column_name']}.#{r['key']}", r['hits']) }
      puts "  … и ещё #{semi.size - 12}" if semi.size > 12
    end

    return if unsampled.empty?

    puts
    puts '== ключи в полях, из которых выборка ничего не дала (поле пустое — не находка) =='
    unsampled.each { |r| puts format('  %-46s %s', "#{r['table_name']}.#{r['column_name']}.#{r['key']}", r['used_in']) }
  end

  desc 'Снять состав служб с живых контейнеров: где что выполняется'
  task places: :environment do
    Xref::Store.migrate!

    (Xref.config[:run_places] || {}).each do |place, cfg|
      print format('%-5s %-6s ', place, cfg[:ssh_host])
      $stdout.flush
      begin
        units = Xref::RunPlaces.collect(place, cfg)
        Xref::Store.write_run_place(place, cfg, units)
        with_task = units.count { |u| u[:rake_task].present? }
        puts "служб #{units.size}, из них rake-роботов #{with_task}: " \
             "#{units.filter_map { |u| u[:rake_task]&.sub('robots:', '') }.join(' ')}"
      rescue StandardError => e
        puts "ОТКАЗ: #{e.message}"
      end
    end
  end

  desc 'Разобрать код: какие таблицы и колонки он трогает (FULL=1 — заново, всё)'
  task code: :environment do
    xref_scan_code(full: ENV['FULL'].present?)

    conn = Xref::Store.conn
    puts
    puts '== что нашлось =='
    conn.select_all(<<~SQL.squish).each do |r|
      select kind, count(*)::int as rows, count(distinct path)::int as files,
             count(distinct token)::int as names
      from code_refs group by kind order by count(*) desc
    SQL
      puts format('  %-12s %7d строк  %5d файлов  %6d имён', r['kind'], r['rows'], r['files'], r['names'])
    end
  end

  desc 'Где трогают таблицу или колонку: bin/xref where NAME=big_users'
  task where: :environment do
    xref_fresh!
    name = xref_arg('NAME').presence or abort 'нужен NAME=<таблица|колонка|таблица.колонка>'
    conn = Xref::Store.conn
    table, column = name.include?('.') ? name.split('.', 2) : [name, nil]

    presence = conn.select_one(<<~SQL.squish)
      select array_to_string(present_in, ',') as present, array_to_string(missing_in, ',') as missing
      from v_table_presence where name = #{conn.quote(table)}
    SQL

    if presence
      puts "== таблица #{table}: есть в [#{presence['present']}]#{presence['missing'].present? ? ", НЕТ в [#{presence['missing']}]" : ''} =="
    else
      puts "== #{table}: такой таблицы нет ни в одном источнике =="
    end

    models = conn.select_one("select array_to_string(models, ', ') as models, array_to_string(paths, ', ') as paths from v_table_models where table_name = #{conn.quote(table)}")
    puts "   модели: #{models['models']}  (#{models['paths']})" if models
    show_ambiguity(conn, column || table)

    if column.nil?
      live = conn.select_one(<<~SQL.squish)
        select coalesce(sum(hits), 0)::bigint as hits, max(last_day) as day,
               coalesce(sum(queries), 0)::int as queries
        from v_runtime_table where table_name = #{conn.quote(table)}
      SQL
      if live && live['hits'].to_i.positive?
        puts format('   в боевых логах за %s: %s выполнений в %s разных запросах — таблица ЖИВА',
                    live['day'], live['hits'], live['queries'])
      elsif conn.select_value('select count(*) from sql_runtime').to_i.positive?
        puts '   в боевых логах за собранные сутки её не трогали (это подозрение, а не приговор:'
        puts '   сутки — короткое окно, и обращения через ORM в логе выглядят иначе)'
      end
      show_usage(conn, "kind in ('pg_table','hb_table') and token = #{conn.quote(table)}", 'разобранный SQL и hbase')
      show_usage(conn, "kind = 'pg_table_guess' and token = #{conn.quote(table)}", 'догадка по неразобранному SQL', limit: 10)
      show_usage(conn, "kind = 'ar_column' and owner = #{conn.quote(table)}", 'обращения через ActiveRecord')
      show_usage(conn, "kind = 'token' and token = #{conn.quote(table)}", 'кандидаты по тексту', limit: 15)
    else
      col = conn.select_one(<<~SQL.squish)
        select array_to_string(present_in, ',') as present, array_to_string(missing_in, ',') as missing,
               array_to_string(types_by_source, ', ') as types
        from v_column_presence where table_name = #{conn.quote(table)} and column_name = #{conn.quote(column)}
      SQL
      if col
        puts "== колонка #{name}: [#{col['present']}]#{col['missing'].present? ? ", НЕТ в [#{col['missing']}]" : ''}"
        puts "   типы: #{col['types']}"
      else
        puts "== колонки #{name} нет ни в одном источнике =="
      end
      show_usage(conn, "kind = 'pg_column' and token = #{conn.quote(column)} and owner = #{conn.quote(table)}",
                 'разобранный SQL: ЧТЕНИЕ, привязано к этой таблице')
      show_usage(conn, "kind = 'pg_column_write' and token = #{conn.quote(column)} and owner = #{conn.quote(table)}",
                 'разобранный SQL: ЗАПИСЬ (цель update/insert)')
      show_usage(conn, "kind = 'pg_column' and token = #{conn.quote(column)} and owner = ''",
                 'разобранный SQL, таблица не определена')
      show_usage(conn, "kind = 'ar_column' and token = #{conn.quote(column)} and owner = #{conn.quote(table)}",
                 'ActiveRecord, привязано к этой таблице')
      show_usage(conn, "kind = 'ar_column' and token = #{conn.quote(column)} and owner = ''",
                 'ActiveRecord, модель не определена')
      # Two kinds linked BY NAME rather than by table: a value is taken out of
      # a result hash, and a name stands inside a string expression. For tables
      # selected with a whole field list this is the only proof of use — and
      # `columns` already counts it. Without these sections two reports about one
      # column answered differently.
      # Where it is visible which query filled the result row, a read does have a
      # table — and that is a link of the same strength as parsed SQL. Dumping
      # both cases into one section called "the table is unknown" means hiding
      # the stronger proof under the weaker caption.
      show_usage(conn, "kind = 'key_read' and token = #{conn.quote(column)} " \
                       "and owner = #{conn.quote(table)}",
                 'берут значение по ключу из строк ЭТОЙ таблицы', limit: 15)
      show_usage(conn, "kind = 'key_read' and token = #{conn.quote(column)} and owner = ''",
                 'берут значение по ключу (связь по ИМЕНИ, таблица неизвестна)', limit: 15)
      show_usage(conn, "kind = 'pg_column_expr' and token = #{conn.quote(column)}",
                 'названа в строке-выражении (связь по ИМЕНИ)', limit: 10)
      show_usage(conn, "kind = 'token' and token = #{conn.quote(column)}", 'кандидаты по тексту', limit: 15)
      show_doc_mentions(conn, column)
    end
  end

  desc 'Роуты: bin/xref route NAME=/letter или NAME=letter_controller'
  task route: :environment do
    xref_fresh!
    name = xref_arg('NAME').presence or abort 'нужен NAME=<кусок пути, имя роута или контроллера>'
    conn = Xref::Store.conn
    like = conn.quote("%#{name.sub(/_controller\z/, '')}%")

    rows = conn.select_all(<<~SQL.squish).to_a
      select verb, path, controller, action, route_name, controller_path
      from v_route_code
      where path ilike #{like} or controller ilike #{like} or coalesce(route_name, '') ilike #{like}
      order by path, verb limit 60
    SQL

    if rows.empty?
      puts "роутов по «#{name}» не найдено"
      next
    end

    rows.each do |r|
      puts format('%-7s %-44s %s#%s', r['verb'], r['path'],
                  r['controller'].presence || '—', r['action'].presence || '—')
      puts "         #{r['controller_path']}" if r['controller_path'].present?
    end
    puts "всего показано: #{rows.size}"
  end

  desc 'Какие вьюхи рисуются на самом деле: разбор логов пумы (DATE=2026-08-21)'
  task views: :environment do
    Xref::Store.migrate!

    day = ENV['DATE'].presence || Date.today.to_s
    places = (Xref.config.dig(:view_logs, :places) || {})
    abort 'в config/xref.yml нет view_logs' if places.empty?

    total = 0
    places.each do |place, cfg|
      Array(cfg[:hosts]).each do |host|
        print format('%-5s %-6s ', place, host)
        $stdout.flush
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          found = Xref::ViewRuntime.collect(host, cfg[:glob].to_s.sub('DATE', day))
        rescue StandardError => e
          puts "ОТКАЗ: #{e.message}"
          next
        end
        # An empty answer does not erase what was collected. A log for a day may
        # sit on the node and contain not a single `Processing by` line (that
        # happens with a file left over from a restart) — and delete+insert with
        # an empty list erased a snapshot collected while the log was still
        # complete. Losing an update is cheaper than losing data.
        if found[:no_logs] || (found[:views].empty? && found[:actions].empty?)
          puts found[:no_logs] ? 'логов за этот день на узле нет' : 'в логах за этот день ни одного запроса'
          puts '        собранное раньше не трогаем'
          next
        end

        rows = found[:views]
        Xref::Store.write_view_runtime(place, host, day, rows)
        Xref::Store.write_action_runtime(place, host, day, found[:actions])
        total += rows.sum { |r| r[:hits] }
        puts format('шаблонов %4d, отрисовок %8d, действий %4d, запросов %8d — за %.0f с',
                    rows.size, rows.sum { |r| r[:hits] },
                    found[:actions].size, found[:actions].sum { |r| r[:hits] },
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end
    end

    conn = Xref::Store.conn
    puts
    puts format('== за %s: отрисовок %d ==', day, total)
    used = conn.select_value("select count(*) from v_view_used where path in (select path from code_files)").to_i
    files = conn.select_value("select count(*) from code_files where path like 'app/views/%'").to_i
    puts "  вьюх видели живьём: #{used} из #{files}"

    unknown = conn.select_all(<<~SQL.squish).to_a
      select u.path, u.hits from v_view_used u
      left join code_files f on f.path = u.path
      where f.path is null and u.path is not null
      order by u.hits desc limit 5
    SQL
    if unknown.any?
      puts "  ! шаблоны, которых нет под индексом: #{unknown.size}"
      unknown.each { |r| puts "      #{r['path']}  #{r['hits']}" }
    end

    # The comparison against the graph — what all of it was collected for.
    only_live = conn.select_value(<<~SQL.squish).to_i
      select count(*) from v_view_used u
      join code_files f on f.path = u.path
      where not exists (select 1 from v_reach r where r.path = u.path)
    SQL
    only_static = conn.select_value(<<~SQL.squish).to_i
      select count(distinct r.path) from v_reach r
      where r.path like 'app/views/%'
        and not exists (select 1 from v_view_used u where u.path = r.path)
    SQL
    puts
    puts '== граф против логов =='
    puts "  рисуются живьём, но графу недостижимы: #{only_live}  (разрешённые render по переменной)"
    puts "  граф считает достижимыми, но за сутки ни разу не рисовались: #{only_static}"
    puts '  Сутки доказывают использование, но не смерть: редкие экраны за день не открывают.'
  end

  # The locale self-check. It DELIBERATELY requires no database: when a command
  # dies on an encoding it dies before any query, and what has to be asked is
  # something that works for certain. It prints non-Latin text next to a value
  # from ENV — exactly the form on which `bin/xref find` with a non-Latin pattern
  # died on 2026-10-09.
  desc 'Локаль и кодировки: bin/xref locale [NAME=образец]'
  task :locale do
    name = xref_arg('NAME').presence || 'образец'
    puts format('локаль %s, внешняя кодировка %s, ярлык ENV %s',
                Encoding.find('locale'), Encoding.default_external, name.encoding)
    puts format('образец «%s» прочитан целиком: %d знаков', name, name.each_char.count)
    puts 'кодировки в порядке' if Encoding.default_external == Encoding::UTF_8
  end

  desc 'Находки по разрядам и надёжность разряда: bin/xref findings [KIND=column]'
  task findings: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    kind = ENV['KIND'].presence

    if kind.nil?
      puts '== находки по разрядам =='
      puts '   «в отчётах» — что показывается СЕЙЧАС: проверенное ложным оттуда убрано,'
      puts '   а подтверждённое настоящим остаётся, пока не починено.'
      puts '   «ложных» — доля ошибок САМОГО ИНСТРУМЕНТА среди проверенных в разряде.'
      puts format('  %-46s %9s %9s %7s', 'разряд', 'в отчётах', 'проверено', 'ложных')
      total_open = 0
      Xref::Verdicts.kinds.each do |name|
        open = conn.select_value(Xref::Verdicts.count_sql(name)).to_i
        rel = Xref::Store.verdict_reliability(name)
        checked = rel ? rel['checked'].to_i : 0
        total_open += open
        share = checked.positive? ? "#{rel['wrong_share']} %" : '—'
        puts format('  %-46s %9d %9s %7s', Xref::Verdicts.title(name)[0, 46], open,
                    checked.positive? ? checked : '—', share)
      end
      puts format('  %-46s %9d', 'всего в отчётах', total_open)
      stale = conn.select_value("select count(*) from v_finding_verdict where state = 'устарел'").to_i
      puts "  ! у #{stale} вердиктов файл после проверки правили — эти находки вернулись в отчёты" if stale.positive?
      puts
      puts '   bin/xref findings <разряд>            — список открытых находок разряда'
      puts '   bin/xref verdict <разряд> <предмет> ложная "почему" [чем]'
      puts '                                         — проверено у первоисточника, запомнить'
      next
    end

    Xref::Verdicts.kind!(kind)
    limit = (ENV['LIMIT'].presence || 40).to_i
    total = conn.select_value(Xref::Verdicts.count_sql(kind)).to_i
    rows = conn.select_all(Xref::Verdicts.open_sql(kind, limit: limit)).to_a
    puts "== #{Xref::Verdicts.title(kind)}: в отчётах #{total} =="
    if rows.empty?
      xref_zero_note('разряд')
    else
      rows.each do |r|
        puts format('  %-66s %s', r['subject'].to_s[0, 66], r['show'].to_s[0, 50])
      end
      puts "   … и ещё #{total - rows.size}" if total > rows.size
    end
    xref_verdict_note(kind)

    # What the journal HIDES — out loud and in the same answer. A report that
    # silently removes findings is more dangerous than a report with noise: the
    # reader does not know what was kept from them.
    hidden = conn.select_all(<<~SQL.squish).to_a
      select subject, reason, checked, checked_at::date as day
      from v_finding_hidden where kind = #{conn.quote(kind)} order by subject limit 40
    SQL
    if hidden.any?
      puts
      puts "== проверено и оказалось ложным — из ответа убрано: #{hidden.size} =="
      hidden.each do |r|
        puts format('  %-66s %s', r['subject'].to_s[0, 66], r['day'])
        puts format('      %s (%s)', r['reason'].to_s[0, 110], r['checked'])
      end
    end
    genuine = conn.select_all(<<~SQL.squish).to_a
      select subject, reason, state, checked_at::date as day
      from v_finding_verdict
      where kind = #{conn.quote(kind)} and verdict = 'настоящая' order by subject limit 40
    SQL
    next if genuine.empty?

    puts
    puts "== проверено и подтверждено: #{genuine.size} =="
    genuine.each do |r|
      puts format('  %-66s %s', r['subject'].to_s[0, 66], r['state'])
      puts format('      %s', r['reason'].to_s[0, 110]) if r['reason'].present?
    end
  end

  desc 'Вердикт о находке: bin/xref verdict KIND=column SUBJECT=… VERDICT=ложная WHY=… [HOW=схемой]'
  task verdict: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    kind = ENV['KIND'].presence or raise Xref::Error,
                                        "KIND=<разряд> обязателен. Есть: #{Xref::Verdicts.kinds.join(', ')}"
    Xref::Verdicts.kind!(kind)
    subject = xref_arg('SUBJECT').presence or raise Xref::Error,
                                              "SUBJECT=<предмет> обязателен — bin/xref findings #{kind} покажет предметы"

    if ENV['VERDICT'].to_s.strip == 'снять'
      gone = Xref::Store.forget_verdict(kind: kind, subject: subject)
      puts gone.to_i.positive? ? "вердикт снят: #{kind} #{subject}" : 'такого вердикта в журнале не было'
      next
    end

    verdict = Xref::Verdicts.word!(ENV['VERDICT'])
    # A verdict without a reason is useless: a month later it can neither be
    # checked nor overturned, while it will go on hiding findings diligently.
    why = xref_arg('WHY').to_s.strip
    raise Xref::Error, 'WHY="почему" обязательно: вердикт без причины через месяц не проверить' if why.empty?

    how = xref_arg('HOW').presence || 'глазами'
    found = conn.select_one(Xref::Verdicts.lookup_sql(kind, conn.quote(subject)))
    if found.nil? && ENV['FORCE'].blank?
      raise Xref::Error, "такой находки в разряде #{kind} нет: #{subject}\n" \
                         "       bin/xref findings #{kind} — список предметов; FORCE=1 — записать всё равно"
    end

    # THE EFFECT, NOT THE FACT OF THE WRITE. A verdict that was written, entered
    # the journal as coverage and yet did NOT suppress the finding is a silent
    # no-op: it looks like work done and lies about what has been verified. That
    # is exactly what happened in another project (2026-10-09): the subject was
    # written with an expression other than the one the report identifies the
    # finding by, and the journal reported "4 verified, 4 false" with four live
    # findings. So the class is counted before and after and the two compared.
    open_before = conn.select_value(Xref::Verdicts.count_sql(kind)).to_i
    Xref::Store.record_verdict(kind: kind, subject: subject, verdict: verdict,
                               checked: how, reason: why, path: found && found['path'])
    open_after = conn.select_value(Xref::Verdicts.count_sql(kind)).to_i

    if verdict == Xref::Verdicts::WRONG && open_after == open_before
      if ENV['FORCE'].present?
        puts '  ! НЕСВЯЗАННЫЙ вердикт: находку он не подавил (FORCE=1). В журнале он есть,'
        puts '    в покрытии разряда считается, а отчёт продолжит её показывать'
      else
        # A lying record is not left behind: it is removed and we fail.
        Xref::Store.forget_verdict(kind: kind, subject: subject)
        raise Xref::Error,
              "вердикт «ложная» записался, но находку НЕ подавил — предмет назван не тем\n" \
              "       выражением, которым её опознаёт отчёт. Запись снята.\n" \
              "       bin/xref findings #{kind} — список предметов как они есть"
      end
    end

    puts "#{Xref::Verdicts.title(kind)}: #{subject}"
    puts "  вердикт: #{verdict} (#{how}) — #{why}"
    if verdict == Xref::Verdicts::WRONG && open_after < open_before
      if found && found['path'].present?
        puts "  из отчётов убрана; вернётся, как только изменится #{found['path']}"
      else
        puts '  из отчётов убрана НАВСЕГДА: у находки нет файла, по правке которого вердикт устарел бы'
      end
    end
    xref_verdict_note(kind)
  end

  desc 'Аудит самого индекса: связность графа, шум, разрывы'
  task audit: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    # PLACES ARE A PREREQUISITE OF REACHABILITY, and their absence must be said
    # rather than printed as zeros. A project without a live service inventory has
    # none; the graph then runs in one synthetic place (`v_places`), and a reader
    # has to know that "reachable from an entry point" is about that single place.
    if conn.select_value('select count(*) from run_units').to_i.zero?
      puts '   мест не описано (bin/xref places): достижимость считается в одном месте local'
    end

    puts '== рёбра графа =='
    conn.select_all('select kind, count(*)::int as n from v_code_edges group by kind order by 2 desc').each do |r|
      puts format('  %-8s %6d', r['kind'], r['n'])
    end

    # Three checks that catch BREAKAGE rather than the unused. They are printed
    # in the audit because both halves — the finding and the noise — age: the
    # noise filtering is tuned to today's tree, and if a number jumps, the parser
    # is what to look at first rather than the code.
    puts
    puts '== поломки, которые видно по схеме =='
    cblind = conn.select_value('select count(*) from v_column_blind').to_i
    defects = conn.select_value('select count(*) from v_column_list_defect').to_i
    puts format('  %-44s %d', 'обращений к колонке, которой в таблице нет:', cblind)
    puts format('  %-44s %d', 'дефектов в списках полей:', defects)
    # The verdict journal. The share of false ones is the reliability of THE
    # TOOL within a class, and its place is in the self-diagnostics: if the share
    # jumped, fix the parse rather than the code.
    hidden = conn.select_value('select count(*) from v_finding_hidden').to_i
    verdicts = conn.select_one(<<~SQL.squish)
      select count(*)::int as all_checked,
             count(*) filter (where verdict = 'ложная')::int as wrong,
             count(*) filter (where state = 'устарел')::int as stale,
             count(distinct kind)::int as kinds
      from v_finding_verdict
    SQL
    if verdicts['all_checked'].to_i.zero?
      puts format('  %-44s %s', 'журнал проверок находок:', 'пуст — bin/xref findings')
      puts '     в новом слое ложных находок в два-три раза больше настоящих (замер 08–09.10):'
      puts '     137 примеров → 7, 632 ссылки → 15, 22 пропуска перевода → 6, 13 колонок → 4'
    else
      puts format('  %-44s %d в %d разрядах, ложных %d, прячут %d находок',
                  'журнал проверок находок:', verdicts['all_checked'], verdicts['kinds'],
                  verdicts['wrong'], hidden)
      puts "     ! у #{verdicts['stale']} вердиктов файл после проверки правили — находки вернулись" if verdicts['stale'].to_i.positive?
    end
    # A guard against the return of that very omission: templates were NOT
    # walked by the tree parser, and accesses by key out of them numbered zero —
    # and a zero looks like "nothing takes it". If there is a zero here again,
    # the template parse is broken rather than the application code.
    erb_keys = conn.select_value("select count(*) from code_refs
                                  where kind = 'key_read' and path like '%.erb'").to_i
    rb_keys = conn.select_value("select count(*) from code_refs
                                 where kind = 'key_read' and path not like '%.erb'").to_i
    puts format('  %-44s %d из кода, %d из шаблонов', 'обращений к колонке по ключу:', rb_keys, erb_keys)
    # The alarm fires only where there ARE templates. In a project without a
    # single one (a library, a service) a zero here is the truth, and shouting
    # about a broken parse at it is a false alarm — exactly what this guard was
    # built to prevent. Caught on the first standalone run, 2026-10-10.
    templates = conn.select_value("select count(*) from code_files where lang = 'view'").to_i
    if erb_keys.zero? && templates.positive?
      puts '  !! из шаблонов НОЛЬ — сломан разбор шаблонов, ответ «не берут» неверен'
    end

    # Files of the application outside the reference graph — by class, so that
    # the number does not read as "a thousand two hundred dead files". The
    # detailed breakdown is in `bin/xref dead`.
    outside = conn.select_one(<<~SQL.squish)
      with out_of_graph as (
        select f.path from code_files f
        where f.path like 'app/%' and not exists (select 1 from v_reach r where r.path = f.path))
      select count(*)::int as total,
             count(*) filter (where path like 'app/views/%')::int as views,
             count(*) filter (where path like 'app/javascript/%')::int as js,
             count(*) filter (where path like 'app/helpers/%')::int as helpers
      from out_of_graph
    SQL
    puts format('  %-44s %d (шаблонов %d, js %d, хелперов %d)',
                'файлов приложения вне графа ссылок:', outside['total'],
                outside['views'], outside['js'], outside['helpers'])

    filled = conn.select_value('select count(distinct table_name) from column_fill').to_i
    if filled.zero?
      puts '  замеров живых данных нет вовсе — bin/xref fill <таблица>'
    else
      puts format('  %-44s %d', 'таблиц с замером живых данных:', filled)
    end

    puts
    puts '== связность =='
    [['app/%.rb', 'файлы приложения'], ['app/views/%', 'вьюхи'], ['lib/%.rb', 'lib']].each do |pattern, title|
      total = conn.select_value("select count(*) from code_files where path like #{conn.quote(pattern)}").to_i
      inside = conn.select_value(<<~SQL.squish).to_i
        select count(distinct f.path) from code_files f
        join v_reach r on r.path = f.path where f.path like #{conn.quote(pattern)}
      SQL
      puts format('  %-18s в графе %5d из %5d', title, inside, total)
    end
    conn.select_all('select depth, count(distinct path)::int as n from v_reach group by depth order by depth').each do |r|
      puts format('  глубина %s: %d', r['depth'], r['n'])
    end

    puts
    puts '== шум: имена, по которым поиск по тексту бесполезен =='
    conn.select_all(<<~SQL.squish).each do |r|
      select token, count(distinct path)::int as files
      from code_refs where kind = 'token'
      group by token order by count(distinct path) desc limit 8
    SQL
      puts format('  %-14s %5d файлов', r['token'], r['files'])
    end

    puts
    puts '== разрывы =='
    broken = conn.select_value(<<~SQL.squish).to_i
      select count(*) from run_units u
      left join code_refs c on c.kind = 'rake_entry' and c.token = u.rake_task
      where u.rake_task is not null and c.token is null
    SQL
    puts "  службы, чья rake-задача не нашлась в коде: #{broken}"
    %w[sql_blind hb_dynamic render_dynamic scan_error].each do |kind|
      n = conn.select_value("select count(*) from code_refs where kind = #{conn.quote(kind)}").to_i
      puts format('  %-15s %5d', kind, n)
    end
    # A file with a NUL byte inside is invisible to the text search ENTIRELY:
    # `rg` silently returns "not found", `git grep` returns "Binary file …
    # matches" instead of the lines. The parse does read it, so the index is
    # obliged to name such files.
    hidden = conn.select_all('select path, lang from v_search_blind order by path').to_a
    if hidden.any?
      puts format('  %-15s %5d  NUL-байт внутри: `rg`/`git grep` их не видят ВОВСЕ',
                  '  поиск слеп', hidden.size)
      hidden.first(5).each { |r| puts format('       %-60s %s', r['path'], r['lang']) }
      puts "       … и ещё #{hidden.size - 5}" if hidden.size > 5
    end
    # Three categories that used to lie in one blind-spot count and thereby
    # inflated it almost twofold: those resolved through an assignment,
    # fragments, and prose.
    puts format('  %-15s %5d  имя собрано на лету, но найдено по присваиванию', '  разрешено', conn.select_value('select count(*) from v_blind_resolved').to_i)
    puts format('  %-15s %5d  кусок запроса или текст, начавшийся с ключевого слова', '  кусок/текст', conn.select_value('select count(*) from v_sql_piece').to_i)
    eats = conn.select_value("select count(*) from code_refs where kind = 'sql_comment_eats'").to_i
    puts format('  %-15s %5d  комментарий `--` съел остаток запроса', '  съеденное', eats) if eats.positive?
    skeletons = conn.select_value("select count(*) from code_refs where kind = 'render_dynamic' and owner = 'skeleton'").to_i
    puts format('  %-15s %5d  из них с узором имени — по ним выданы рёбра-кандидаты', '  из них узор', skeletons)

    # `select *` is the largest thing that used to be AN ASSUMPTION rather than
    # a measurement: the report held that listing every column proves nothing
    # (otherwise no column would ever come out unused), but there was nothing to
    # check that with. The check is the line below: for how many tables with a
    # star is there no access by a VARIABLE key left, which could take anything.
    stars = conn.select_one(<<~SQL.squish)
      select count(*)::int as tables, coalesce(sum(places), 0)::int as places,
             count(*) filter (where keys_dynamic = 0 and keys_dynamic_file = 0)::int as proven,
             coalesce(sum(places) filter (where keys_dynamic = 0 and keys_dynamic_file = 0), 0)::int as proven_places
      from v_star_coverage
    SQL
    puts format('  %-15s %5d  мест `select *` на %d таблицах; у %d звезда не прячет ничего (%d мест)',
                'звёзды', stars['places'], stars['tables'], stars['proven'], stars['proven_places'])

    # The newer layers: documentation, configuration, scripts, the front end. In
    # the self-diagnostics they are needed for the same reason as everything
    # else — so that a zero reads as a zero rather than as "this layer does not
    # exist". Until 2026-10-08 the index saw 8,291 files out of 23,337, and the
    # silence about the rest looked like their absence.
    layers = conn.select_one(<<~SQL.squish)
      select (select count(*) from code_files where lang = 'markdown')::int as docs,
             (select count(*) from code_files where lang in ('yaml', 'json'))::int as confs,
             (select count(*) from code_files where lang = 'shell')::int as shells,
             (select count(*) from code_files where lang = 'conf')::int as fronts,
             (select count(*) from v_doc_link_broken)::int as broken,
             (select count(distinct target) from v_doc_path where kind = 'НЕТ ТАКОГО ФАЙЛА')::int as stale,
             (select count(*) from v_doc_code where verdict = 'НЕ РАЗОБРАЛСЯ')::int as bad_code,
             (select count(*) from v_conf_defect)::int as front_defects,
             (select count(*) from v_sh_dangerous)::int as risky,
             (select count(distinct name) from v_env_usage
              where app_files = 0 and task_files = 0 and sh_files > 0)::int as shell_env
      from (select 1) q
    SQL
    # The SQL blind spot is measured not only by the number of unparsed strings:
    # what matters more is how many holes stand in the position of a table name
    # and how many of those are explained.
    holes = conn.select_one(<<~SQL.squish)
      select count(*)::int as total,
             count(*) filter (where context in ('table', 'glue'))::int as naming,
             (select count(distinct (path, root, context)) from v_sql_hole_carries_sql
               where match in ('файл', 'класс'))::int as carries
      from v_sql_holes
    SQL
    puts format('  %-15s %5d  из них в позиции имени таблицы: %d, приносят собранный SQL: %d (bin/xref holes)',
                'дыр в запросах', holes['total'], holes['naming'], holes['carries'])
    puts
    puts '== слои за пределами ruby: документы, настройки, скрипты, фронт, javascript =='
    puts format('  %-15s %5d  битых ссылок %d, устаревших путей %d, примеров без разбора %d',
                'документы', layers['docs'], layers['broken'], layers['stale'], layers['bad_code'])
    puts format('  %-15s %5d  ключей среды читают только скрипты: %d',
                'скрипты', layers['shells'], layers['shell_env'])
    puts format('  %-15s %5d  опасных мест (снос, права) в скриптах: %d',
                'настройки', layers['confs'], layers['risky'])
    puts format('  %-15s %5d  дефектов конфигурации: %d (bin/xref front)',
                'конфиги фронта', layers['fronts'], layers['front_defects'])
    css = conn.select_one(<<~SQL.squish)
      select (select count(*) from v_css_file)::int as files,
             (select count(distinct name) from v_css_class)::int as classes,
             (select count(*) from v_css_class_usage where verdict = 'НЕ ПОМИНАЕТ НИКТО')::int as nobody,
             (select count(*) from v_css_unreachable where kind = 'КАНДИДАТ НА СНЯТИЕ')::int as orphan,
             (select count(*) from v_css_blind)::int as blind
    SQL
    puts format('  %-15s %5d  классов %d, не поминает никто %d, файлов без подключения %d',
                'стили', css['files'], css['classes'], css['nobody'], css['orphan'])
    puts format('  %-15s %5s  имя класса собрано ЦЕЛИКОМ в %d местах — слой об них не знает',
                '  слепота', '', css['blind'])
    js = conn.select_one(<<~SQL.squish)
      select (select count(*) from code_files where lang = 'js')::int as files,
             (select count(distinct r.path) from v_reach r join code_files f on f.path = r.path
               where f.lang = 'js')::int as reachable,
             (select count(distinct to_path) from v_js_edges)::int as imported,
             (select count(*) from v_stimulus_registry)::int as registered,
             (select count(*) from v_stimulus_registry where templates = 0)::int as orphan,
             (select count(*) from v_stimulus_action where verdict <> 'метод есть')::int as bad_action,
             (select count(*) from v_stimulus_use where not registered)::int as bad_use,
             (select count(*) from v_js_unreachable where kind = 'КАНДИДАТ НА СНЯТИЕ')::int as dead
    SQL
    puts format('  %-15s %5d  импорт ведёт в %d, достижимо от точки входа %d, контроллеров %d (без шаблона %d)',
                'javascript', js['files'], js['imported'], js['reachable'], js['registered'], js['orphan'])
    puts format('  %-15s %5s  сломанных действий %d, незарегистрированных включений %d, мёртвых файлов %d',
                '  Stimulus', '', js['bad_action'], js['bad_use'], js['dead'])


    # The blind spots of a render — out loud and by name. Silence here would read
    # as "there are no links", while in fact it is "the name sits entirely in a
    # variable, and I do not know".
    blind_renders = conn.select_all(<<~SQL.squish).to_a
      select path, token, array_to_string(lines, ',') as lines
      from v_render_blind order by path, token limit 15
    SQL
    total_blind = conn.select_value('select count(*) from v_render_blind').to_i
    puts
    puts "== рендеры, у которых имя вьюхи целиком в переменной: #{total_blind} =="
    puts '   Узора нет, кандидатов нет: индекс честно не знает, куда они ведут.'
    blind_renders.each do |r|
      puts format('   %-58s %-28s стр. %s', r['path'], r['token'][0, 28], r['lines'])
    end
    puts "   … и ещё #{total_blind - blind_renders.size}" if total_blind > blind_renders.size

    stale = conn.select_all(<<~SQL.squish).to_a
      select source, taken_at from v_current
      where taken_at < now() - interval '1 day' order by taken_at
    SQL
    next if stale.empty?

    puts
    puts '== снимки старше суток =='
    stale.each { |r| puts "  #{r['source']}  #{r['taken_at']}" }
  end

  desc 'Кто дотягивается до файла: bin/xref callers PATH=app/models/order.rb'
  task callers: :environment do
    target = ENV['PATH_TO'].presence || ENV['FILE'].presence or abort 'нужен FILE=<путь к файлу>'
    xref_fresh!
    conn = Xref::Store.conn

    quoted = conn.quote(target)
    unless conn.select_value("select count(*) from code_files where path = #{quoted}").to_i.positive?
      abort "файла #{target} нет под индексом"
    end

    places = conn.select_values("select place || ' (гл.' || depth || ')' from v_reach where path = #{quoted} order by place")
    puts "== #{target}"
    puts places.any? ? "   выполняется в: #{places.join(', ')}" : '   ни одно место до файла не дотягивается'

    puts
    puts '== кто ссылается напрямую (имя вьюхи стоит в коде целиком) =='
    direct = conn.select_all(<<~SQL.squish).to_a
      select from_path, kind, scope from v_code_edges
      where to_path = #{quoted} and kind <> 'render?'
      order by kind, from_path limit 40
    SQL
    if direct.empty?
      puts '   никто — файл либо точка входа, либо достижим только динамически'
    else
      direct.each { |r| puts format('   %-8s %s%s', r['kind'], r['from_path'], r['scope'].to_s.empty? ? '' : "  [#{r['scope']}]") }
    end

    # The candidates are kept apart from the facts, the same way pg_table is kept
    # apart from token: the view name there is assembled at runtime, and only the
    # pattern out of the literal pieces matched.
    candidates = conn.select_all(<<~SQL.squish).to_a
      select r.path as from_path, r.token as glob, array_to_string(r.lines, ',') as lines
      from code_refs r
      join code_refs v on v.kind = 'view_name' and v.path = #{quoted}
                      and (v.token like (r.detail->>'glob') escape '~'
                           or v.token like ('%/' || (r.detail->>'glob')) escape '~')
      where r.kind = 'render_dynamic' and r.owner = 'skeleton'
        and r.detail->>'glob' is not null and r.path <> v.path
      order by r.path limit 40
    SQL
    if candidates.any?
      puts
      puts '== кандидаты: имя вьюхи собрано на ходу, совпал узор =='
      candidates.uniq { |r| [r['from_path'], r['glob']] }.each do |r|
        puts format('   render?  %-58s %s  стр. %s', r['from_path'], r['glob'], r['lines'])
      end
      puts '   Это догадка по литеральным кускам имени, а не разобранный вызов.'
    end

    live = conn.select_all(<<~SQL.squish).to_a
      select action, hits, array_to_string(places, ',') as places
      from v_view_actions where path = #{quoted} order by hits desc limit 15
    SQL
    if live.any?
      puts
      puts '== кто рисовал её на самом деле (по боевым логам) =='
      live.each { |r| puts format('   %-46s %8s отрисовок  [%s]', r['action'], r['hits'], r['places']) }
    end

    puts
    puts '== точки входа, которые до него доходят =='
    entries = conn.select_all(<<~SQL.squish).to_a
      with recursive back (path, depth) as (
        select #{quoted}, 0
        union
        select e.from_path, b.depth + 1
        from back b join v_code_edges e on e.to_path = b.path
        where b.depth < 9
      )
      select distinct e.kind, e.entry, e.path, min(b.depth) as depth
      from back b join v_entry_points e on e.path = b.path
      group by e.kind, e.entry, e.path
      order by min(b.depth), e.kind, e.entry limit 40
    SQL
    if entries.empty?
      puts '   ни одной — до файла не дотягивается ни контроллер, ни работа, ни робот'
    else
      entries.each { |r| puts format('   %-11s %-40s %s  гл.%s', r['kind'], r['entry'], r['path'], r['depth']) }
    end

    # A Stimulus controller is called not by code but by THE MARKUP:
    # `data-controller` in a template. An import graph will never show that,
    # while the question "who attaches it" is the main one for such a file.
    stimulus = conn.select_all(<<~SQL.squish).to_a
      select g.identifier, u.path, u.lines[1] as line
      from v_stimulus_registry g
      left join v_stimulus_use u on u.identifier = g.identifier
      where g.source = #{quoted} order by u.path limit 20
    SQL
    if stimulus.any?
      identifier = stimulus.first['identifier']
      templates = stimulus.reject { |r| r['path'].nil? }
      puts
      puts "== это контроллер Stimulus «#{identifier}», его включает разметка: #{templates.size} шаблонов =="
      if templates.empty?
        puts '   НИ ОДИН шаблон его не включает: он попадает в пакет и грузится,'
        puts '   но не активируется нигде (bin/xref js — весь разряд)'
      else
        templates.first(12).each { |r| puts format('   %-62s стр. %s', r['path'][0, 62], r['line']) }
        puts "   … и ещё #{templates.size - 12}" if templates.size > 12
      end
    end

    # Who WROTE ABOUT a file is as legitimate a question as who calls it, and
    # before the documentation was parsed there was no answer to it. An edit to a
    # file that has a document about it is obliged to reach the document too.
    docs = conn.select_all(<<~SQL.squish).to_a
      select doc, kind, lines[1] as line from v_doc_for_path
      where path = #{quoted} order by doc limit 15
    SQL
    if docs.any?
      puts
      puts "== про этот файл написано: #{docs.size} документов =="
      puts '   правка файла, про который есть документ, обязана дойти и до документа'
      docs.each { |r| puts format('   %-58s %s:%s', r['doc'][0, 58], r['kind'], r['line']) }
    end

    puts
    puts '   Граф строится по ссылкам на константы, render и связям моделей.'
    puts '   Вызов на объекте и send ему невидимы: пустой ответ ничего не доказывает.'
    puts '   Рёбра render? — кандидаты по узору имени, а не разобранные вызовы.'
  end

  desc 'Слепые зоны: где имя таблицы собирается на лету и индекс бессилен'
  task blind: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    breaks = conn.select_all(<<~SQL.squish).to_a
      select table_name, place, path, kind, depth, lines
      from v_break_here order by table_name, place, path
    SQL
    puts '== таблицы в этом месте нет, а код туда дотягивается =='
    if breaks.empty?
      places = conn.select_value('select count(*) from run_units').to_i
      puts places.zero? ? '  состав служб не снят: bin/xref places' : '  таких нет'
    else
      breaks.each do |r|
        puts format('  %-26s [%-3s] %-48s гл.%s  стр. %s',
                    r['table_name'], r['place'], r['path'], r['depth'], r['lines'])
      end
      puts '  Достижимость — оценка по ссылкам на константы: каждую строку надо'
      puts '  проверить глазами, а отсутствие строки ничего не доказывает.'
    end

    puts
    puts '== имя таблицы собирается на лету или SQL не разобран =='
    rows = conn.select_all(<<~SQL.squish).to_a
      select b.kind, b.path, b.count, array_to_string(b.lines, ',') as lines, b.token,
             b.detail->>'expr' as expr,
             (select string_agg(distinct h.expr, ' | ') from v_sql_holes h
               where h.path = b.path and h.lines && b.lines) as holes
      from v_blind b order by b.count desc, b.path limit 40
    SQL
    rows.each do |r|
      puts format('  %-11s %-52s %3d  стр. %s', r['kind'], r['path'], r['count'], r['lines'])
      puts "      #{r['token'][0, 120]}" if r['kind'] == 'sql_blind'
      # What the name is assembled from. Previously the report only said
      # "assembled at runtime", and one had to work it out by eye from the line
      # in the file.
      puts "      подставляется: #{(r['holes'] || r['expr']).to_s[0, 120]}" if (r['holes'] || r['expr']).present?
    end
    total = conn.select_value('select count(*) from v_blind').to_i
    puts "  … всего #{total}" if total > rows.size
    resolved = conn.select_all('select table_name, path, count from v_blind_resolved
                                order by count desc limit 8').to_a
    if resolved.any?
      full = conn.select_value('select count(*) from v_blind_resolved').to_i
      puts
      puts "== имя собрано на лету, но найдено по присваиванию: #{full} =="
      puts '   это не слепая зона: переменная присвоена в том же файле, имя известно'
      resolved.each { |r| puts format('  %-30s %-50s %d', r['table_name'], r['path'], r['count']) }
    end
    # The log knows the RESOLVED name where the code assembles it by
    # interpolation. This is the only source that closes that blind spot rather
    # than describing it.
    from_logs = conn.select_all(<<~SQL.squish).to_a
      select g.token as stem, string_agg(distinct rt.table_name, ', ' order by rt.table_name) as seen,
             coalesce(sum(rt.hits), 0)::bigint as hits
      from code_refs g
      join v_runtime_table rt on rt.table_name like g.token || '%' and rt.table_name <> g.token
      where g.kind = 'pg_table_guess'
      group by 1 order by 3 desc limit 12
    SQL
    if from_logs.any?
      puts
      puts "== чем это было в бою: #{from_logs.size} узоров разрешено логами =="
      puts '   имя собрано интерполяцией, но лог пумы пишет уже разрешённое имя'
      from_logs.each { |r| puts format('  %-26s %-70s %s', "#{r['stem']}…", r['seen'][0, 70], r['hits']) }
    end

    pieces = conn.select_value('select count(*) from v_sql_piece').to_i
    if pieces.positive?
      puts
      puts "== кусок запроса или текст, а не запрос: #{pieces} =="
      puts '   строка обрывается на полуслове или это фраза, начавшаяся с ключевого'
      puts '   слова («Select a valid review status»). Не знать тут нечего.'
    end

    puts
    puts '== код трогает таблицу, которой где-то нет (без учёта места исполнения) =='
    miss = conn.select_all(<<~SQL.squish).to_a
      select table_name, array_to_string(missing_in, ',') as missing, files,
             array_to_string(sample, ', ') as sample
      from v_missing_table_usage order by files desc, table_name
    SQL
    if miss.empty?
      puts '  таких нет'
    else
      miss.first(40).each do |r|
        puts format('  %-34s нет в [%s]  %d файлов', r['table_name'], r['missing'], r['files'])
        puts "      #{r['sample']}"
      end
      puts "  … всего #{miss.size}" if miss.size > 40
    end

    puts
    puts '== код трогает таблицу, которой нет нигде =='
    unknown = conn.select_all(<<~SQL.squish).to_a
      select table_name, files, array_to_string(sample, ', ') as sample
      from v_unknown_table_usage order by files desc, table_name limit 40
    SQL
    if unknown.empty?
      puts '  таких нет'
    else
      unknown.each { |r| puts format('  %-34s %d файлов   %s', r['table_name'], r['files'], r['sample']) }
    end
  end

  desc 'Дыры в запросах: что подставляется интерполяцией и откуда оно берётся'
  task holes: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    name = xref_arg('NAME').presence

    if name
      like = conn.quote("%#{name}%")
      rows = conn.select_all(<<~SQL.squish).to_a
        select path, root, context, expr, scopes as scope, sql, fragment,
               array_to_string(lines, ',') as lines, count
        from v_sql_holes
        where root = #{conn.quote(name)} or expr ilike #{like} or path ilike #{like}
        order by path, root limit 60
      SQL
      puts "== дыры по «#{name}»: #{rows.size} =="
      rows.each do |r|
        puts format('  %-52s %-13s %s%s', r['path'], xref_place(r['context']), r['expr'],
                    r['fragment'] ? '   [обрывок]' : '')
        puts "      #{r['scope'].presence || '—'}  стр. #{r['lines']}   #{r['sql'].to_s[0, 110]}"
      end

      # The root is a method parameter: the text comes from the caller, and
      # staying silent about that is not allowed. Who calls it is a question for
      # a call graph, which does not exist.
      params = conn.select_all(<<~SQL.squish).to_a
        select path, root, context, scope, method, array_to_string(lines, ',') as lines
        from v_sql_hole_from_param where root = #{conn.quote(name)} order by path limit 20
      SQL
      params.each do |r|
        puts format('  %-52s %-13s параметр метода %s — источник у вызывающего',
                    r['path'], xref_place(r['context']), r['method'])
      end
      next
    end

    total = conn.select_value('select count(*) from v_sql_holes').to_i
    files = conn.select_value('select count(distinct path) from v_sql_holes').to_i
    fragments = conn.select_value('select count(*) from v_sql_holes where fragment').to_i
    puts "== куда подставляется: #{total} дыр в #{files} файлах =="
    conn.select_all(<<~SQL.squish).each do |r|
      select context, count(*) as n, count(distinct path) as files,
             count(*) filter (where fragment) as frag
      from v_sql_holes group by 1 order by 1
    SQL
      puts format('  %-28s %5d в %3d файлах%s', xref_place(r['context']), r['n'], r['files'],
                  r['frag'].to_i.positive? ? "   из них в обрывках: #{r['frag']}" : '')
    end
    puts '  Дыра в позиции имени таблицы — это место, где индекс не знает, какую'
    puts '  таблицу трогает код. Теперь он хотя бы знает, ЧЕМ это имя собирается.'
    puts "  Обрывок (#{fragments}) — подстановка в кусок запроса без select и from"
    puts '  («user_id in (…)», «where …»). Целого запроса рядом нет, разбирать нечего,'
    puts '  но место в запросе читается — и глаз такое проскакивает легче всего.'

    puts
    puts '== в дыру приходит не значение, а собранный запрос =='
    carries = conn.select_all(<<~SQL.squish).to_a
      select c.path, c.root, c.context, c.expr, array_to_string(c.hole_lines, ',') as lines,
             bool_or(h.fragment) as fragment, count(*) as sources,
             to_jsonb((array_agg(c.source_kind || ' ' || c.source_path ||
                       case when c.source_form <> '' then ' (' || c.source_form || ')' else '' end ||
                       case when c.source_value <> '' then '  «' || left(c.source_value, 80) || '»' else '' end
                       order by c.source_kind))[1:3]) as top
      from v_sql_hole_carries_sql c
      join v_sql_holes h on h.path = c.path and h.root = c.root and h.context = c.context
      where c.match in ('файл', 'класс')
      group by c.path, c.root, c.context, c.expr, c.hole_lines order by c.context, c.path
    SQL
    if carries.empty?
      puts '  таких нет'
    else
      carries.each do |r|
        puts format('  %-46s %-13s %s  стр. %s%s', r['path'], xref_place(r['context']),
                    r['expr'], r['lines'], r['fragment'] ? '  [обрывок]' : '')
        JSON.parse(r['top']).each { |src| puts "      <- #{src}" }
        puts "      … и ещё #{r['sources'].to_i - 3} источников" if r['sources'].to_i > 3
      end
    end

    # The root of a hole is a method parameter: the source is not in this file
    # but at the caller. Saying so out loud is cheaper than staying silent:
    # otherwise an empty answer reads as "there is no source", while there is one
    # and it sits one step above.
    from_param = conn.select_all(<<~SQL.squish).to_a
      select p.path, p.context, p.root, p.method, array_to_string(p.lines, ',') as lines
      from v_sql_hole_from_param p
      where p.context in ('in_list', 'condition', 'table', 'glue')
      order by p.path, p.lines limit 25
    SQL
    if from_param.any?
      puts
      puts '== текст приходит от вызывающего: корень дыры — параметр метода =='
      from_param.each do |r|
        puts format('  %-46s %-13s %s  в %s  стр. %s', r['path'], xref_place(r['context']),
                    r['root'], r['method'], r['lines'])
      end
      puts '  bin/xref calls NAME=<метод> — кто зовёт и что передаёт в этот параметр.'
    end
    weak = conn.select_value("select count(*) from v_sql_hole_carries_sql where match = 'имя'").to_i
    puts "  ещё #{weak} связей найдено только по совпадению имени — это не находки, а шум:" if weak.positive?
    puts "  bin/xref holes NAME=<имя> покажет их с местом объявления." if weak.positive?

    puts
    puts '== имя таблицы или его часть собирается на лету =='
    conn.select_all(<<~SQL.squish).each do |r|
      select path, root, context, expr, sql, array_to_string(lines, ',') as lines
      from v_sql_holes where context in ('table', 'glue') order by context, path limit 40
    SQL
      puts format('  %-46s %-13s %s', r['path'], xref_place(r['context']), r['expr'])
      puts "      стр. #{r['lines']}   #{r['sql'].to_s[0, 110]}"
    end

    puts
    puts '== в запрос подставляется то, что пришло в запросе браузера =='
    params = conn.select_all(<<~SQL.squish).to_a
      select path, context, expr, scope, array_to_string(lines, ',') as lines
      from v_sql_holes
      where expr ~ '\\mparams\\s*\\[' or expr ~ '\\mparams\\.(fetch|dig|require|permit)\\M'
      order by path limit 40
    SQL
    if params.empty?
      puts '  таких нет'
    else
      params.each do |r|
        puts format('  %-46s %-13s %-28s стр. %s', r['path'], xref_place(r['context']),
                    r['expr'][0, 28], r['lines'])
      end
      puts '  Проверяется глазами: рядом может стоять to_i или явный список значений.'
    end
  end

  desc 'Кто вызывает метод и что передаёт: bin/xref calls NAME=make_param'
  task calls: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    name = xref_arg('NAME').presence

    # What counts as "a query arrived in the argument". Two sets, both small:
    # variables that had SQL assigned to them within their own file, and methods
    # that return SQL. The index can say no more about an argument than that —
    # and should not.
    sql_assigns = conn.select_rows('select path, name from v_assigns where is_sql or is_part').to_set
    sql_methods = conn.select_values('select distinct method from v_defs where returns_sql or returns_part').to_set

    classify = lambda do |text, path|
      root = text.to_s[/\A[@$]{0,2}[A-Za-z_][A-Za-z0-9_]*/].to_s
      call = text.to_s[/\.\s*([a-z_]\w*)[!?]?\s*[({]?\z/, 1] || text.to_s[/\A[A-Z][\w:]*\.\s*([a-z_]\w*)/, 1]
      if text.match?(/\A['"%]\s*\(?\s*(select|with)\b/i) then 'запрос'
      elsif text.start_with?("'", '"', '%') then 'строка'
      elsif text.match?(/\A-?\d+\z/) then 'число'
      elsif sql_assigns.include?([path, root]) then 'запрос (переменная)'
      elsif sql_methods.include?(root) || (call && sql_methods.include?(call)) then 'запрос (метод)'
      else 'прочее'
      end
    end

    # The parameters that end up in a hole: only those are of interest here.
    wanted = conn.select_all(<<~SQL.squish).to_a
      select path, method, root as param, context, array_to_string(lines, ',') as lines, params
      from v_sql_hole_from_param
      where context in ('in_list', 'condition', 'table', 'glue')
        #{name ? "and method = #{conn.quote(name)}" : ''}
      order by method, path
    SQL
    if wanted.empty? && name.nil?
      puts 'дыр, чей корень — параметр метода, не нашлось'
      next
    end

    names = name ? [name] : wanted.map { |r| r['method'] }.uniq
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stats = {}
    calls = Xref::CallSites.find(names, stats: stats).group_by(&:method)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    if name
      defs = conn.select_all(<<~SQL.squish).to_a
        select path, class_name, singleton, array_to_string(params, ', ') as params,
               array_to_string(lines, ',') as lines, params as param_list
        from v_defs where method = #{conn.quote(name)} order by path
      SQL
      puts "== #{name}: объявлений #{defs.size} =="
      defs.each do |d|
        puts format('  %-52s %s%s%s(%s)  стр. %s', d['path'], d['class_name'],
                    d['singleton'] ? '.' : '#', name, d['params'], d['lines'])
      end
      puts '  ! имя объявлено в нескольких местах — вызовы ниже могут вести не сюда' if defs.size > 1

      # It is not code that calls it. A controller action may have not a single
      # call in the tree and still run on every request; a job's `perform` is
      # called by the scheduler. Without this check "there are no calls" would
      # read as "dead".
      paths = defs.map { |d| conn.quote(d['path']) }.join(',').presence || "''"
      conn.select_all(<<~SQL.squish).each do |r|
        select 'роутер' as who, r.verb || ' ' || r.path as what, c.path as file
        from app_routes r
        join app_controllers c on c.class_name = r.controller_class
        where r.action = #{conn.quote(name)} and c.path in (#{paths})
        union all
        select 'планировщик', j.job_key || coalesce(' ' || j.cron, ''), j.path
        from app_jobs j
        where #{conn.quote(name)} in ('perform', 'perform_now') and j.path in (#{paths})
      SQL
        puts format('  зовёт %s: %s  (%s)', r['who'], r['what'], r['file'])
      end

      # method_missing in the same class — a call may bypass the name entirely.
      missing = conn.select_values(<<~SQL.squish)
        select distinct path from v_defs
        where method = 'method_missing' and path in (#{paths})
      SQL
      puts "  ! в этом файле есть method_missing (#{missing.join(', ')}) — зовут, возможно, мимо имени" if missing.any?
      wanted.each do |r|
        puts format('  в запрос уходит параметр %s (%s), стр. %s', r['param'], r['context'], r['lines'])
      end

      order = defs.first&.[]('param_list').to_s.delete('{}').split(',')
      rows = calls[name].to_a
      puts
      by_via = rows.group_by { |c| c.via || 'ruby' }.map { |k, v| "#{k} #{v.size}" }.join(', ')
      puts "== вызовов: #{rows.size} (#{by_via.present? ? "#{by_via}; " : ''}" \
           "#{stats[:files]} файлов за #{format('%.1f', elapsed)} с) =="
      if rows.empty?
        # An empty list is an answer rather than silence. The reasons are named
        # explicitly.
        puts '  по имени не зовут нигде — ни из ruby, ни из шаблонов, ни через send'
        puts '  с именем-литералом. Остаётся method_missing и имя, собранное на лету.'
      end
      if stats[:dynamic_sends].to_i.positive?
        puts "  ! рядом #{stats[:dynamic_sends]} вызовов send с именем, собранным на лету, — любой может звать этот метод"
      end

      rows.sort_by { |c| [c.path, c.line] }.first(60).each do |call|
        puts format('  %s:%d  %s%s', call.path, call.line, call.scope.presence || '—',
                    call.via ? "  [#{call.via}]" : '')
        if call.args.empty?
          puts '      без аргументов — возможно, это чтение переменной, а не вызов'
          next
        end
        call.args.each_with_index do |arg, index|
          param = order[index].to_s.presence || "арг.#{index + 1}"
          puts format('      %-14s %-58s %s', param, arg[0, 58], classify.call(arg, call.path))
        end
      end
      puts "  … показаны первые 60" if rows.size > 60

      # Mentions outside calls. Printed always when there are few of them, and
      # necessarily when there are no calls: "the method is dead" without this
      # list reads as "I will delete it", while what keeps such a method alive is
      # a spec or an inventory — and it has to be removed as a pair.
      mentions = Xref::CallSites.mentions(name, skip: rows)
      if mentions.any? && (rows.empty? || mentions.size <= 15 || ENV['MENTIONS'].present?)
        puts
        puts "== упоминания вне вызовов: #{mentions.size} =="
        mentions.first(25).each do |m|
          puts format('  %-52s:%-5d %-12s %s', m.path, m.line, m.kind, m.text[0, 90])
        end
        puts "  … и ещё #{mentions.size - 25}" if mentions.size > 25
        puts '  Снимать мёртвый метод — вместе с тем, что его держит.' if rows.empty?
      elsif mentions.any?
        puts "  ещё #{mentions.size} упоминаний вне вызовов (спеки, описи, документы): MENTIONS=1"
      end
      next
    end

    # How many times this name is declared at all. `count` is declared in the
    # tree more than once, and it has a thousand and a half calls — those are
    # somebody else's `count`, not ours. A summary over such a name means
    # nothing, and showing it as a fact is not allowed.
    def_counts = conn.select_rows(<<~SQL.squish).to_h
      select method, count(*)::int from v_defs
      where method in (#{names.map { |n| conn.quote(n) }.join(',')}) group by 1
    SQL

    puts "== что передают в параметры, которые уходят в запрос (#{names.size} методов, #{format('%.1f', elapsed)} с) =="
    wanted.group_by { |r| [r['method'], r['param'], r['context']] }.each do |(method, param, context), group|
      rows = calls[method].to_a
      label = format('%-30s %-16s', "#{method}(#{param})", xref_place(context))
      if rows.size > 200 || def_counts[method].to_i > 3
        puts "  #{label} #{rows.size} вызовов — имя частое (#{def_counts[method]} объявлений), сводка не значит ничего"
        next
      end

      order = group.first['params'].to_s.delete('{}').split(',')
      index = order.index(param)
      kinds = Hash.new(0)
      rows.each do |call|
        text = index && call.args[index] ? call.args[index] : nil
        kinds[text ? classify.call(text, call.path) : 'аргумент не передан'] += 1
      end
      summary = kinds.sort_by { |_, n| -n }.map { |kind, n| "#{kind} #{n}" }.join(', ')
      if rows.empty?
        # A dead method comes straight away with whatever keeps it in an
        # inventory.
        held = Xref::CallSites.mentions(method).group_by(&:kind).transform_values(&:size)
        summary = 'по имени не зовут нигде'
        summary += "; держат упоминания: #{held.map { |k, n| "#{k} #{n}" }.join(', ')}" if held.any?
      end
      summary += "  [#{def_counts[method]} объявления]" if def_counts[method].to_i > 1
      puts format('  %s %4d вызовов: %s', label, rows.size, summary)
    end
    puts
    puts '  «аргумент не передан» — вызов с меньшим числом аргументов: либо у'
    puts '  параметра есть умолчание, либо это вообще другой метод с тем же именем.'
    puts "  Считаны ruby, шаблоны ERB и send с именем-литералом; #{stats[:dynamic_sends]} send"
    puts '  собирают имя на лету — эти могут звать что угодно.'
    puts '  bin/xref calls NAME=<метод> — все вызовы поимённо, с аргументами.'
  end

  desc 'Компонентная модель: роли, границы и кто впитал чужие обязанности'
  task components: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    components = Xref::Components.all
    if components.empty?
      puts 'в config/xref.yml нет раздела components'
      next
    end

    # THE MODEL REVIEW first, the violations second: forbidding by a wrong
    # mapping is worse than not forbidding at all.
    membership = Xref::Components.membership(conn: conn)
    total = conn.select_value('select count(*) from code_files').to_i
    overlap = membership.select { |_, names| names.size > 1 }
    unmarked = total - membership.size

    puts "== модель: #{components.size} компонентов, размечено #{membership.size} из #{total} файлов =="
    components.each do |component|
      size = membership.count { |_, names| names.include?(component.name) }
      puts format('  %-22s %-8s %5d файлов   %s', component.name, component.role, size,
                  component.paths.join(', '))
    end

    puts
    puts '== ревью модели =='
    if overlap.any?
      puts "  ! файл в нескольких компонентах: #{overlap.size} — разметка неоднозначна"
      overlap.first(5).each { |path, names| puts "      #{path}: #{names.join(', ')}" }
    else
      puts '  образцы не пересекаются: каждый файл принадлежит одному компоненту'
    end
    if unmarked.positive?
      share = (100.0 * unmarked / total).round
      puts "  ! не размечено #{unmarked} файлов (#{share} %)"
      conn.select_all(<<~SQL.squish).each { |r| puts "      #{r['dir']}: #{r['n']}" }
        select regexp_replace(path, '/[^/]+$', '') as dir, count(*)::int as n
        from code_files
        where not (#{components.map { |c| c.condition(conn) }.join(' or ')})
        group by 1 order by 2 desc limit 5
      SQL
      puts '      пока эта масса велика, модель описывает не дерево, а его часть' if share > 20
    end

    edges = Xref::Components.edges(conn: conn)
    degree = edges.group_by { |edge| edge[:from].name }
    wide = degree.select { |_, list| list.size >= components.size - 2 }
    if wide.any?
      puts "  ! компонент говорит почти со всеми — кандидат на «огромное общее»:"
      wide.each { |name, list| puts "      #{name}: зависит от #{list.size} компонентов из #{components.size}" }
    end

    cycles = Xref::Components.cycles(conn: conn)
    strong, weak = cycles.partition { |pair| pair[:strong] }
    if strong.any?
      puts
      puts "== впитал чужие обязанности: #{strong.size} пар =="
      strong.each do |pair|
        puts format('  %s <-> %s: %d рёбер туда, %d обратно',
                    pair[:names].first, pair[:names].last,
                    pair[:forward][:edges], pair[:backward][:edges])
      end
      puts '  Зависимость существенна в ОБЕ стороны — никакой порядок слоёв такую'
      puts '  пару не разведёт. Похоже, один из двух компонентов держит две'
      puts '  обязанности и его надо разделить. Разметкой по путям это не видно.'
    end
    if weak.any?
      puts
      puts "== одиночные обратные ссылки: #{weak.size} пар =="
      weak.first(8).each do |pair|
        thin = [pair[:forward], pair[:backward]].min_by { |edge| edge[:edges] }
        puts format('  %-22s -> %-22s %d рёбер в %d файлах (против %d в другую сторону)',
                    thin[:from].name, thin[:to].name, thin[:edges], thin[:files],
                    [pair[:forward], pair[:backward]].max_by { |e| e[:edges] }[:edges])
      end
      puts '  Это не впитанная обязанность, а несколько ссылок: лечится точечно.'
    end

    puts
    mutual = cycles.flat_map { |pair| [pair[:names], pair[:names].reverse] }
    upward = edges.select { |edge| edge[:upward] && !mutual.include?([edge[:from].name, edge[:to].name]) }
    puts "== зависимости ВВЕРХ по слоям (без взаимных пар): #{upward.size} =="
    if upward.empty?
      puts '  таких нет: ни один компонент не зависит от слоя выше себя'
    else
      upward.sort_by { |edge| -edge[:edges] }.each do |edge|
        puts format('  %-22s (%-7s) -> %-22s (%-7s) %4d рёбер в %d файлах',
                    edge[:from].name, edge[:from].role, edge[:to].name, edge[:to].role,
                    edge[:edges], edge[:files])
      end
      puts '  Порядок слоёв: api -> ui -> service -> domain -> shared/infra;'
      puts '  shared доступен всем, от test и infra не зависит никто.'
    end
  end

  desc 'Архитектурные правила: где граф их нарушает (config/xref.yml, раздел rules)'
  task rules: :environment do
    xref_fresh!
    results = Xref::Rules.check
    if results.empty?
      puts 'в config/xref.yml нет раздела rules'
      next
    end
    unless Xref::Rules.ready?
      puts '! рёбер графа нет: ноль нарушений у любого правила значит «не смотрели»'
      puts '  сначала bin/xref app и bin/xref code'
      next
    end

    puts "== правил: #{results.size}. Защёлка: отчёт кричит, когда число выросло =="
    results.each do |result|
      puts
      puts format('-- %s: %d нарушений в %d файлах, защёлка %d — %s',
                  result.name, result.count, result.files, result.limit, result.state)
      puts "   почему: #{result.why}"
      next if !result.grown? && ENV['ALL'].blank?

      limit = ENV['ALL'].present? ? 40 : 15
      result.rows.first(limit).each do |row|
        puts format('   %-52s -> %-44s %s', row['from_path'], row['to_path'], row['kind'])
      end
      puts "   … и ещё #{result.count - limit}" if result.count > limit
    end

    grown = results.count(&:grown?)
    puts
    if grown.positive?
      puts "== выросло правил: #{grown}. Это и есть повод для разбора. =="
    else
      puts '== всё в пределах защёлок. ALL=1 покажет сами нарушения. =='
    end

    # Second half of the report: a contract declared in prose, and the latch
    # that is supposed to break when the tree drifts away from it. Ported from a
    # second project, where this check produced the finding it exists for — "the
    # contract is written down and nothing enforces it".
    contracts = Xref::Rules.contracts
    if contracts.empty?
      puts
      puts 'в config/xref.yml нет раздела contracts — объявленные текстом правила не проверяются'
      next
    end

    broken = contracts.select(&:broken?)
    puts
    puts "== контрактов, объявленных текстом: #{contracts.size}, без работающей защёлки: #{broken.size} =="
    contracts.each do |contract|
      puts format(' %s %-52s %s', contract.broken? ? '!' : ' ', contract.name[0, 52], contract.state)
      puts format('     объявлен: %-46s%s', contract.doc, contract.doc_exists ? '' : ' (ДОКУМЕНТА НЕТ)')
      next unless contract.latch_exists && contract.token_files.positive?

      puts format('     защёлка:  %-46s называет «%s» в %d файлах',
                  contract.latch, contract.token, contract.token_files)
    end
    puts
    puts 'ЧЕГО ЭТА ПРОВЕРКА НЕ ЗНАЕТ: падает ли защёлка при расхождении. Видно, что файл'
    puts 'есть и что он называет предмет контракта; прогон спек индексу недоступен.'
  end

  desc 'Что задето правкой: методы, их вызывающие, таблицы и ДЦ (REF=HEAD~3)'
  task changed: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    ref = ENV['REF'].presence || 'HEAD'

    changed = xref_changed_lines(ref)
    if changed.empty?
      puts "против #{ref} изменений нет"
      next
    end

    ruby = changed.select { |path, _| path.match?(/\.(rb|rake|ru)\z/) }
    puts "== правка против #{ref}: #{changed.size} файлов, из них ruby #{ruby.size} =="

    affected = []
    ruby.each do |path, lines|
      spans = xref_defs_in(path)
      inside = spans.select { |span| lines.any? { |line| line.between?(span['from'], span['to']) } }
      outside = lines.reject { |line| spans.any? { |span| line.between?(span['from'], span['to']) } }
      affected.concat(inside.map { |span| span.merge('path' => path) })
      puts format('  %-52s строк %-4d методов %d%s', path, lines.size, inside.size,
                  outside.any? ? "  (+#{outside.size} строк вне методов: тело класса, константы)" : '')
      inside.first(12).each do |span|
        puts format('      %s%s%s  стр. %d–%d', span['class_name'], span['singleton'] ? '.' : '#',
                    span['method'], span['from'], span['to'])
      end
    end
    other = changed.keys - ruby.keys
    if other.any?
      by_dir = other.group_by { |path| File.dirname(path) }.transform_values(&:size)
      puts "  не ruby: #{by_dir.sort_by { |_, n| -n }.map { |dir, n| "#{dir} (#{n})" }.join(', ')[0, 150]}"
    end

    if affected.any?
      puts
      puts '== кто зовёт задетые методы =='
      names = affected.map { |span| span['method'] }.uniq
      stats = {}
      calls = Xref::CallSites.find(names, stats: stats).group_by(&:method)
      # How many times the name is declared at all: for a frequent name the list
      # of calls is noise rather than an answer. `scan` is called a thousand
      # times, and not one of those calls need have anything to do with the edit.
      def_counts = conn.select_rows(<<~SQL.squish).to_h
        select method, count(*)::int from v_defs
        where method in (#{names.map { |n| conn.quote(n) }.join(',')}) group by 1
      SQL
      names.sort.each do |name|
        rows = calls[name].to_a.reject { |call| affected.any? { |s| s['path'] == call.path && s['method'] == name } }
        if rows.empty?
          puts format('  %-34s вызовов по имени нет', name)
          next
        end
        if rows.size > 200 || def_counts[name].to_i > 3
          puts format('  %-34s %4d вызовов — имя частое (%d объявлений), разбирать по одному',
                      name, rows.size, def_counts[name])
          next
        end

        by_file = rows.group_by(&:path)
        puts format('  %-34s %3d вызовов в %d файлах: %s', name, rows.size, by_file.size,
                    by_file.keys.first(3).join(', ')[0, 90])
      end
      puts "  ! рядом #{stats[:dynamic_sends]} send с именем на лету" if stats[:dynamic_sends].to_i.positive?
    end

    # What all of it was collected for: the edit touches a table that some data
    # centre does not have, and from the code that is not visible.
    puts
    puts '== таблицы, которых касается правка =='
    quoted = changed.keys.map { |path| conn.quote(path) }.join(',')
    tables = conn.select_all(<<~SQL.squish).to_a
      select r.token as name, r.kind, array_agg(distinct r.path) as paths,
             array_to_string(tp.present_in, ',') as present,
             array_to_string(tp.missing_in, ',') as missing
      from code_refs r
      left join v_table_presence tp on tp.name = r.token
      where r.path in (#{quoted}) and r.kind in ('pg_table', 'pg_table_guess', 'hb_table')
      group by r.token, r.kind, tp.present_in, tp.missing_in
      order by r.token
    SQL
    if tables.empty?
      puts '  правка таблиц не касается'
    else
      tables.each do |row|
        warn_text = if row['present'].nil? then '  ! такой таблицы нет ни в одном источнике'
                    elsif row['missing'].present? then "  ! НЕТ в [#{row['missing']}]"
                    else ''
                    end
        puts format('  %-32s %-15s %s%s', row['name'], row['kind'],
                    row['paths'].to_s.delete('{}').split(',').first, warn_text)
      end
      puts '  Проверять по месту исполнения: bin/xref blind покажет, дотягивается ли туда код.'
    end

    views = changed.keys.select { |path| path.start_with?('app/views/') }
    next if views.empty?

    puts
    puts '== правка в шаблонах: кто их рисует и сколько раз =='
    conn.select_all(<<~SQL.squish).each do |row|
      select f.path, coalesce(u.hits, 0)::bigint as hits, coalesce(u.actions, 0) as actions,
             (select count(*) from v_code_edges e where e.to_path = f.path)::int as refs
      from code_files f
      left join v_view_used u on u.path = f.path
      where f.path in (#{views.map { |path| conn.quote(path) }.join(',')})
      order by hits desc
    SQL
      puts format('  %-56s отрисовок %-9s из действий %-3s ссылок %s',
                  row['path'], row['hits'], row['actions'], row['refs'])
    end
  end

  desc 'От задачи к файлам: bin/xref scope NAME="/letter" (роут, действие, таблица, слово)'
  task scope: :environment do
    xref_fresh!
    name = xref_arg('NAME').presence or abort 'нужен NAME=<роут, действие, таблица, файл или слово>'
    conn = Xref::Store.conn
    like = conn.quote("%#{name}%")
    # `NAME=users.email` is a task about A COLUMN, and there is no table with
    # that name: without splitting on the dot such an input answered "nothing
    # found" out of nothing. But `%users%` is not allowed here either: that is
    # ten tables belonging to other things. A table name is matched exactly,
    # while the column itself becomes an entry point into the scope.
    column = name.include?('.') ? name : nil
    table_match = column ? "= #{conn.quote(name.split('.').first)}" : "ilike #{like}"
    depth = (ENV['DEPTH'].presence || 2).to_i
    limit = (ENV['LIMIT'].presence || 12).to_i

    # The order here IS the answer: the scenario, then the map, then the
    # sources. An entry through a file (`boundary`) starts in the middle — it
    # cannot answer "where does this task live at all".
    puts "== задача «#{name}»: сначала точки входа, потом карта, потом исходники =="

    routes = conn.select_all(<<~SQL.squish).to_a
      select r.verb, r.path, r.controller_class, r.action, r.route_name, c.path as file,
             coalesce((select sum(hits) from v_action_used u
                        where u.action = r.controller_class || '#' || r.action), 0)::bigint as hits
      from app_routes r
      left join app_controllers c on c.class_name = r.controller_class
      where r.path ilike #{like} or coalesce(r.route_name, '') ilike #{like}
         or r.controller ilike #{like} or coalesce(r.controller_class, '') ilike #{like}
      order by hits desc, r.path limit 25
    SQL

    tables = conn.select_all(<<~SQL.squish).to_a
      select name, array_to_string(present_in, ',') as present, array_to_string(missing_in, ',') as missing
      from v_table_presence where name #{table_match} order by name limit 10
    SQL

    direct = conn.select_values(<<~SQL.squish)
      select path from code_files where path ilike #{like} order by path limit 10
    SQL

    puts
    puts "-- точки входа: роутов #{routes.size}"
    if routes.any?
      routes.first(8).each do |row|
        puts format('   %-7s %-40s %s#%s%s', row['verb'], row['path'].to_s[0, 40],
                    row['controller_class'], row['action'],
                    row['hits'].to_i.positive? ? "  (#{row['hits']} запросов в наблюдении)" : '')
      end
      puts "   … и ещё #{routes.size - 8}" if routes.size > 8
    end
    puts "-- таблицы по имени: #{tables.size}" if tables.any?
    tables.each do |row|
      warn_text = row['missing'].present? ? "  ! НЕТ в [#{row['missing']}]" : ''
      puts format('   %-32s есть в [%s]%s', row['name'], row['present'], warn_text)
    end
    puts "-- файлы по имени: #{direct.size}" if direct.any?
    direct.first(5).each { |path| puts "   #{path}" }

    # A column sits in the index as a token with the table as its owner rather
    # than as the string `table.column`: a search by the full name would find no
    # records at all.
    column_seed = if column
                    table, field = name.split('.', 2)
                    conn.select_values(<<~SQL.squish)
                      select distinct path from code_refs
                      where owner = #{conn.quote(table)}
                        and (kind in ('pg_column', 'pg_column_write') and token = #{conn.quote(field)}
                             or kind = 'col_list' and token ~ #{conn.quote("\\m#{field}\\M")})
                      limit 40
                    SQL
                  else
                    []
                  end
    table_seed = conn.select_values(<<~SQL.squish)
      select distinct path from code_refs
      where kind in ('pg_table', 'pg_table_guess')
        and token in (select name from v_table_presence where name #{table_match})
      limit 40
    SQL
    # A task about a column is NOT a task about the table: forty files touching
    # `big_users` inflate the scope from seven files to a hundred and sixty. The
    # table is taken only when nothing was found by the column.
    table_seed = [] if column && column_seed.any?
    seed = (routes.map { |row| row['file'] } + direct + column_seed + table_seed).compact.uniq
    if column_seed.any?
      puts "-- файлы, где эта колонка в запросе: #{column_seed.size}"
      column_seed.first(5).each { |path| puts "   #{path}" }
      puts "   … и ещё #{column_seed.size - 5}" if column_seed.size > 5
    end
    if seed.empty?
      puts
      puts '   ни роута, ни таблицы, ни файла по этому имени не нашлось'
      xref_zero_note('ответ')
      next
    end

    quoted_seed = seed.map { |path| conn.quote(path) }.join(',')
    # The map: what these files need, step by step. The rank is production
    # renders first, then the number of references: read first what also works
    # most often.
    rows = conn.select_all(<<~SQL.squish).to_a
      with recursive walk (path, step) as (
        select path, 0 from code_files where path in (#{quoted_seed})
        union
        select e.to_path, w.step + 1
        from walk w join v_code_edges e on e.from_path = w.path and e.scope = ''
        where w.step < #{depth}
      )
      select w.path, min(w.step) as step,
             coalesce((select sum(hits) from v_view_used u where u.path = w.path), 0)::bigint as hits,
             (select count(*) from v_code_edges e where e.to_path = w.path)::int as refs
      from walk w
      where w.path not in (#{quoted_seed})
      group by w.path order by min(w.step), hits desc, refs desc
    SQL

    # Shrinking the area to read is the whole point of this report. "89 files to
    # read first" shrinks nothing, so the step is split by component, and code
    # comes before templates: to edit logic one reads the models and the library
    # rather than every partial the controller renders.
    membership = Xref::Components.membership(conn: conn)
    components = Xref::Components.all.to_h { |item| [item.name, item] }
    order = { 'api' => 1, 'service' => 2, 'domain' => 3, 'shared' => 4, 'infra' => 5,
              'ui' => 6, 'test' => 7 }

    rows.group_by { |row| row['step'] }.sort_by { |step, _| step }.each do |step, list|
      puts
      puts "-- #{step == 1 ? 'читать первым' : "дальше, шаг #{step}"}: #{list.size} файлов"
      groups = list.group_by { |row| membership[row['path']]&.first || 'прочее' }
      groups.sort_by { |name, _| [order[components[name]&.role] || 8, name] }.each do |name, files|
        role = components[name]&.role
        cap = role == 'ui' ? 4 : limit
        puts format('   %s (%s): %d', name, role || '—', files.size)
        files.first(cap).each do |row|
          marks = []
          marks << "#{row['hits']} отрисовок" if row['hits'].to_i.positive?
          marks << "#{row['refs']} ссылок" if row['refs'].to_i.positive?
          puts format('     %-56s %s', row['path'], marks.join(', '))
        end
        puts "     … и ещё #{files.size - cap}" if files.size > cap
      end
    end

    # Read the sources already knowing what will break: the tables and the blind
    # spots.
    all_paths = (seed + rows.map { |row| row['path'] }).uniq
    quoted_all = all_paths.map { |path| conn.quote(path) }.join(',')
    danger = conn.select_all(<<~SQL.squish).to_a
      select r.token as name, array_to_string(tp.missing_in, ',') as missing,
             count(distinct r.path)::int as files
      from code_refs r
      join v_table_presence tp on tp.name = r.token
      where r.path in (#{quoted_all}) and r.kind in ('pg_table', 'pg_table_guess')
        and cardinality(tp.missing_in) > 0
      group by 1, 2 order by 3 desc limit 10
    SQL
    if danger.any?
      puts
      puts "-- таблицы, которых где-то нет: #{danger.size}"
      danger.each { |row| puts format('   %-32s НЕТ в [%s]  в %d файлах', row['name'], row['missing'], row['files']) }
    end

    blind = conn.select_value("select count(*) from v_blind where path in (#{quoted_all})").to_i
    holes = conn.select_value("select count(*) from v_sql_holes where path in (#{quoted_all})").to_i

    # The control check from the registry: "does the map find a known DISTANT
    # dependency". It is made measurable like this: how many files came ONLY
    # through the reference graph and hold not a single word of the task in their
    # path.
    #
    # Two limits on the count are deliberate. The words are taken separately
    # (`users.email` is two words), otherwise the count is overstated: no path
    # holds the whole name with the dot in it. And the count starts from the
    # files of the step, without the initial ones: the initial ones were found by
    # a name, a table or a column, which is exactly what a search finds too.
    words = name.downcase.scan(/[a-z0-9_]+/).select { |item| item.length >= 3 }
    walked = rows.map { |row| row['path'] }
    far = walked.reject { |path| words.any? { |item| path.downcase.include?(item) } }
    puts
    puts format('-- всего в области: %d файлов, слепых мест %d, дыр в запросах %d',
                all_paths.size, blind, holes)
    if words.any? && far.any?
      puts format('   из них %d пришли только по графу и не содержат ни одного слова задачи (%s) в пути — по имени файла их не найти:',
                  far.size, words.join(', '))
      # In the examples code comes before templates and the near step before the
      # far one: showing four partials from the second step makes the finding
      # look smaller than it is. The distant dependency worth naming lies in
      # what is to be read first.
      rank = rows.to_h { |row| [row['path'], row['step'].to_i] }
      far.sort_by { |path| [path.start_with?('app/views') ? 1 : 0, rank[path] || 0, path] }
         .first(4).each { |path| puts "     #{path}  (шаг #{rank[path] || 0})" }
    end
    puts '   дальше читать исходники — но уже зная, где у этой области слепые зоны'
  end

  desc 'Что читать для правки: bin/xref boundary FILE=app/models/invoice.rb'
  task boundary: :environment do
    xref_fresh!
    file = ENV['FILE'].presence or abort 'нужен FILE=<путь>'
    conn = Xref::Store.conn
    quoted = conn.quote(file)
    limit = (ENV['LIMIT'].presence || 14).to_i

    exists = conn.select_value("select 1 from code_files where path = #{quoted}")
    abort "#{file} под индексом нет — проверьте путь" unless exists

    puts "== что читать для правки #{file} =="
    puts '   Список отранжирован: сверху то, без чего правку не понять.'

    # Graph neighbours in both directions plus the evidence from production:
    # whoever is rendered and called more often is to be read first.
    rows = conn.select_all(<<~SQL.squish).to_a
      with inbound as (
        select e.from_path as path, 'зовёт этот файл (' || e.kind || ')' as why, 1 as rank
        from v_code_edges e where e.to_path = #{quoted}
      ),
      outbound as (
        select e.to_path as path, 'нужен этому файлу (' || e.kind || ')' as why, 2 as rank
        from v_code_edges e where e.from_path = #{quoted}
      ),
      models as (
        select m.path, 'модель таблицы ' || m.table_name as why, 3 as rank
        from app_models m
        where m.path is not null and m.table_name in (
          select token from code_refs where path = #{quoted} and kind in ('pg_table', 'hb_table')
        )
      ),
      specs as (
        select f.path, 'спека рядом' as why, 4 as rank
        from code_files f
        where f.path like 'spec/%' and f.path like '%' || regexp_replace(#{quoted}, '^app/|\\.rb$', '', 'g') || '%'
      ),
      all_rows as (
        select * from inbound union all select * from outbound
        union all select * from models union all select * from specs
      )
      select a.path, min(a.rank) as rank, string_agg(distinct a.why, '; ') as why,
             coalesce((select sum(hits) from v_view_used u where u.path = a.path), 0)::bigint as hits
      from all_rows a
      where a.path <> #{quoted}
      group by a.path
      order by min(a.rank) * 10 + case when a.path like 'spec/%' then 5 else 0 end, hits desc, a.path
    SQL

    if rows.empty?
      puts '  соседей в графе нет: файл либо изолирован, либо достижим только динамически'
    else
      rows.first(limit).each do |row|
        puts format('  %-56s %s%s', row['path'], row['why'].to_s[0, 60],
                    row['hits'].to_i.positive? ? "  (#{row['hits']} отрисовок)" : '')
      end
      puts "  … и ещё #{rows.size - limit} соседей (LIMIT=#{rows.size} покажет всех)" if rows.size > limit
    end

    # What is not visible in a list of files and has to be known before an edit.
    place = conn.select_all(<<~SQL.squish).to_a
      select place, depth from v_reach where path = #{quoted} order by place
    SQL
    puts "   выполняется в: #{place.map { |r| "#{r['place']} (гл.#{r['depth']})" }.join(', ')}" if place.any?

    missing = conn.select_all(<<~SQL.squish).to_a
      select r.token as name, array_to_string(tp.missing_in, ',') as missing
      from code_refs r join v_table_presence tp on tp.name = r.token
      where r.path = #{quoted} and r.kind in ('pg_table', 'pg_table_guess')
        and cardinality(tp.missing_in) > 0
      order by r.token
    SQL
    missing.each { |row| puts "   ! таблицы #{row['name']} нет в [#{row['missing']}]" }

    holes = conn.select_value("select count(*) from v_sql_holes where path = #{quoted}").to_i
    blind = conn.select_value("select count(*) from v_blind where path = #{quoted}").to_i
    puts "   дыр в запросах: #{holes}, слепых мест: #{blind} — bin/xref holes #{file}" if holes.positive? || blind.positive?
  end

  desc 'Роуты, действия и контроллеры, которых никто не трогает'
  task dead_routes: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    days = conn.select_one('select min(day) as a, max(day) as b, count(distinct day) as n from action_runtime')
    window = days['n'].to_i
    puts "== чем доказываем: строки `Processing by` из боевых логов за #{window} суток (#{days['a']} — #{days['b']}) =="
    if window.zero?
      puts '  наблюдений нет — сначала bin/xref views DATE=…; пока считаем только статику'
    else
      seen = conn.select_value('select count(*) from v_action_used').to_i
      puts "  действий встречено: #{seen}. Считаются ЗАПРОСЫ, а не отрисовки: действие,"
      puts '  отвечающее редиректом или json-ом, шаблонов не рисует и по ним выглядело бы'
      puts '  мёртвым. Присутствие — доказательство жизни; отсутствие за неполные'
      puts "  #{window} суток — подозрение, и только."
    end

    puts
    puts '== роут ведёт в действие, которого нет =='
    broken = conn.select_all(<<~SQL.squish).to_a
      select r.verb, r.path, r.controller_class, r.action, c.path as file
      from app_routes r
      join app_controllers c on c.class_name = r.controller_class
      where r.action <> '' and cardinality(c.actions) > 0 and not (r.action = any(c.actions))
      order by r.controller_class, r.action, r.path
    SQL
    if broken.empty?
      puts '  таких нет'
    else
      broken.each do |r|
        puts format('  %-7s %-44s %s#%s  (%s)', r['verb'], r['path'], r['controller_class'], r['action'], r['file'])
      end
      puts '  Такой запрос падает: действия с этим именем в контроллере нет.'
    end

    used = Xref::CallSites.route_helpers
    literal = Xref::CallSites.literal_paths
    puts
    puts '== роут никто не поминает — ни помощником, ни строкой — и в логах его не видно =='
    quiet = conn.select_all(<<~SQL.squish).to_a
      select r.verb, r.path, r.controller_class, r.action, r.route_name,
             coalesce(u.hits, 0)::bigint as hits
      from app_routes r
      left join v_action_used u on u.action = r.controller_class || '#' || r.action
      where r.controller_class is not null and r.action <> ''
      order by r.path, r.verb
    SQL
    # A bare route path: `/pay_center/add_set(/:id)` -> `/pay_center/add_set`.
    silent = quiet.select do |r|
      base = r['path'].to_s.sub(/\(.*\z/, '').sub(%r{/\z}, '').downcase
      r['hits'].to_i.zero? &&
        (r['route_name'].blank? || !used.include?(r['route_name'])) &&
        !literal.include?(base) &&
        !base.include?(':')
    end
    if silent.empty?
      puts '  таких нет'
    else
      silent.group_by { |r| r['controller_class'] }.sort_by { |_, rows| -rows.size }.first(25).each do |klass, rows|
        puts format('  %-34s %d роутов: %s', klass, rows.size,
                    rows.first(6).map { |r| "#{r['verb'].presence || 'ANY'} #{r['path']}" }.join(', ')[0, 110])
      end
      puts "  всего #{silent.size} роутов из #{quiet.size}"
    end

    puts
    puts '== действие есть, а роута на него нет =='
    # `action_methods` in Rails is EVERY public method of a controller rather
    # than only the actions. Shared methods from concerns land in every
    # controller that includes them: one URL helper was listed as "an action
    # with no route" nine times in a row. We cut off whatever occurs in more
    # than three controllers, plus the explicit link helpers.
    unrouted = conn.select_all(<<~SQL.squish).to_a
      select c.class_name, c.path, a.action
      from app_controllers c
      cross join lateral unnest(c.actions) as a(action)
      where c.path not like '/%'
        and a.action not like '%\\_url' and a.action not like '%\\_path'
        and not exists (
          select 1 from app_routes r
          where r.controller_class = c.class_name and r.action = a.action
        )
        and (select count(*) from app_controllers x where a.action = any(x.actions)) <= 3
      order by c.class_name, a.action
    SQL
    if unrouted.empty?
      puts '  таких нет'
    else
      unrouted.group_by { |r| r['class_name'] }.sort_by { |_, rows| -rows.size }.first(20).each do |klass, rows|
        puts format('  %-34s %-42s %s', klass, rows.first['path'],
                    rows.map { |r| r['action'] }.join(', ')[0, 84])
      end
      puts "  всего #{unrouted.size} у #{unrouted.map { |r| r['class_name'] }.uniq.size} контроллеров."
      puts '  Публичный метод контроллера — ещё не действие: его могут звать из вьюхи'
      puts '  или хелпера. Но роута на него нет, а значит снаружи он недостижим.'
    end

    puts
    puts '== контроллер: ни одного роута =='
    orphans = conn.select_all(<<~SQL.squish).to_a
      select c.class_name, c.path, cardinality(c.actions) as actions,
             (select count(*) from code_refs r
               where r.kind = 'const_ref' and r.token = c.class_name and r.path <> c.path)::int as refs
      from app_controllers c
      where c.path is not null and c.path not like '/%'
        and not exists (select 1 from app_routes r where r.controller_class = c.class_name)
      order by refs, c.class_name
    SQL
    if orphans.empty?
      puts '  таких нет'
    else
      orphans.each do |r|
        note = r['refs'].to_i.zero? ? 'на него никто не ссылается' : "ссылок из кода: #{r['refs']} (наследуют?)"
        puts format('  %-38s %-46s действий %-3s  %s', r['class_name'], r['path'], r['actions'], note)
      end
    end

    if window.positive?
      puts
      puts "== контроллер: за #{window} суток ни одного запроса ни в одно действие =="
      cold = conn.select_all(<<~SQL.squish).to_a
        select c.class_name, c.path, cardinality(c.actions) as actions
        from app_controllers c
        where c.path not like '/%'
          and exists (select 1 from app_routes r where r.controller_class = c.class_name)
          and not exists (select 1 from v_action_used u where split_part(u.action, '#', 1) = c.class_name)
        order by c.class_name
      SQL
      cold.first(40).each { |r| puts format('  %-38s %-46s действий %s', r['class_name'], r['path'], r['actions']) }
      puts "  всего #{cold.size}. Это шорт-лист на разбор, а не приговор: наблюдение"
      puts '  неполное, а часть контроллеров живёт от случая к случаю (админка, разборы).'
    end
  end

  desc 'Методы, которых никто не зовёт (VIS=public|all, AREA=app/models — только там)'
  task dead: :environment do
    xref_fresh!
    conn = Xref::Store.conn
    area = xref_arg('AREA').presence || 'app/,lib/'
    # Private ones by default: for them "no calls by name" is almost a proof,
    # because they cannot be called from outside the class anyway. For a public
    # method the same thing only means "not called within this tree" — a gem, a
    # framework or somebody else's code may call it, and the list comes out
    # longer and weaker.
    levels = case ENV['VIS'].to_s
             when 'public' then %w[public]
             when 'all' then %w[private protected public]
             else %w[private protected]
             end
    like = area.split(',').map { |prefix| "d.path like #{conn.quote("#{prefix.strip}%")}" }.join(' or ')

    # Names called not by code but by the language and the framework:
    # `initialize` is called by `new`, `method_missing` by Ruby itself,
    # `perform` by the scheduler. Searching for their calls is pointless, while
    # they would all land in the list of the dead at once.
    framework = %w[
      initialize method_missing respond_to_missing? to_s to_str to_a to_h to_i to_json inspect
      hash eql? == <=> each call coerce perform up down change setup teardown
      default_url_options current_user current_ability
    ]

    # A controller action is called by the router rather than by code: the
    # `not exists` below is about that.
    # The comment stands HERE rather than inside the query: `.squish` collapses
    # the SQL into one line, and everything after `--` becomes a comment to the
    # end of the query — the condition is silently switched off while the report
    # looks like it works.
    defs = conn.select_all(<<~SQL.squish).to_a
      select d.path, d.method, d.class_name, d.singleton, d.visibility,
             array_to_string(d.lines, ',') as lines, d.size,
             (select count(*) from v_defs a where a.method = d.method)::int as namesakes
      from v_defs d
      where d.visibility in (#{levels.map { |v| conn.quote(v) }.join(',')}) and (#{like})
        and d.method not in (#{framework.map { |f| conn.quote(f) }.join(',')})
        and d.path not like 'spec/%' and d.path not like 'db/migrate/%'
        and not exists (
          select 1 from app_routes r
          where r.controller_class = d.class_name and r.action = d.method
        )
      order by d.path, d.method
    SQL
    if defs.empty?
      puts "методов (#{levels.join(', ')}) в #{area} не нашлось — сначала bin/xref code"
      next
    end

    names = defs.map { |d| d['method'] }.uniq
    # Walking the whole tree at once: there are thousands of names, and a grep
    # over them would return almost every file. Each file is read once and only
    # the names needed are looked at.
    paths = conn.select_values("select path from code_files where lang in ('ruby', 'view') order by path")
    puts "== ищем вызовы #{names.size} имён по #{paths.size} файлам, это несколько секунд =="
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stats = {}
    seen = Xref::CallSites.find(names, paths: paths, stats: stats)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    # A declaration of its own does not count as a call: `def x` never reaches
    # the record, while `private :x` is a symbol on the same page and would bring
    # everything back to life.
    own = defs.to_h { |d| [[d['path'], d['method']], d['lines'].split(',').map(&:to_i)] }
    hits = Hash.new { |store, key| store[key] = [] }
    seen.each do |call|
      next if call.via&.include?('символ') && own[[call.path, call.method]]&.any? { |line| (call.line - line).abs <= 1 }

      hits[call.method] << call
    end

    dead = defs.reject { |d| hits.key?(d['method']) }
    # What keeps the dead alive: a spec, an inventory, a document, an analysis
    # script. It has to be removed as a pair, and without this list "dead" reads
    # as "I will delete it".
    # What the mentions were searched with goes into the answer: a text search
    # and a full pass have different prices (1 s against 14) and different
    # coverage (the pass skips files larger than 4 MB, and in one such file a
    # mention was found that it never saw).
    mention_stats = {}
    held = Xref::CallSites.mentions_many(dead.map { |d| d['method'] }.uniq, stats: mention_stats)
    dead.each do |d|
      others = held[d['method']].reject { |m| m.path == d['path'] && (m.line - d['lines'].split(',').first.to_i).abs <= 1 }
      d['held'] = others.group_by(&:kind).transform_values(&:size)
    end
    free, tied = dead.partition { |d| d['held'].empty? }

    # The method lengths come from the index: the parse computed them while it
    # already held the tree in its hands. Previously the report re-read and
    # re-parsed with Prism every file with a finding, and did so three times.
    lines_of = ->(rows) { rows.sum { |row| row['size'].to_i } }
    all_lines = lines_of.call(defs)
    dead_lines = lines_of.call(dead)
    free_lines = lines_of.call(free)
    share = ->(part, whole) { whole.zero? ? '—' : format('%.1f%%', 100.0 * part / whole) }

    puts "== ни одного вызова: #{dead.size} из #{defs.size} (#{share.call(dead.size, defs.size)}), " \
         "#{format('%.0f', elapsed)} с =="
    puts "   из них ничем не помянуты: #{free.size} (#{share.call(free.size, defs.size)}), " \
         "помянуты где-то ещё: #{tied.size}"
    if mention_stats[:scan].present?
      puts "   упоминания искали: #{mention_stats[:scan]}" \
           "#{mention_stats[:lines] ? ", строк-кандидатов #{mention_stats[:lines]}" : ''}"
    end
    puts "   в строках: тела этих методов #{all_lines}, без вызовов #{dead_lines} " \
         "(#{share.call(dead_lines, all_lines)}), из них ничем не помянуты #{free_lines} " \
         "(#{share.call(free_lines, all_lines)})"
    [['ничто не держит — снимается в одиночку', free],
     ['держат упоминания — снимать парой', tied]].each do |title, group|
      next if group.empty?

      puts
      puts "== #{title}: #{group.size} =="
      group.group_by { |d| File.dirname(d['path']) }.sort_by { |dir, _| dir }.each do |dir, rows|
        puts "-- #{dir}: #{rows.size}"
        rows.first(30).each do |d|
          risk = d['namesakes'].to_i > 1 ? "  (имя ещё #{d['namesakes'].to_i - 1} раз — возможен super)" : ''
          holds = d['held'].any? ? "  ← #{d['held'].map { |kind, n| "#{kind} #{n}" }.join(', ')}" : ''
          puts format('  %-46s %s%s%s  стр. %s%s%s', File.basename(d['path']), d['class_name'],
                      d['singleton'] ? '.' : '#', d['method'], d['lines'], risk, holds)
        end
        puts "  … и ещё #{rows.size - 30}" if rows.size > 30
      end
    end

    puts
    puts "  Считаны вызовы, символы (`before_action :x`), send с именем-литералом,"
    puts "  ruby и шаблоны ERB. НЕ считаны: #{stats[:dynamic_sends]} send с именем на лету,"
    puts '  method_missing, define_method и вызовы из yml/json.'
    puts '  bin/xref calls <метод> — по одному имени, с упоминаниями вне вызовов.'

    # FILES OUTSIDE THE REFERENCE GRAPH. There are more than a thousand of them,
    # and as one number they are useless: most are templates whose name is
    # assembled at runtime, that is, an undercount of THE GRAPH rather than the
    # death of a file. They are separated by the strength of the conclusion, and
    # only what has no reference by name at all is called a removal candidate.
    # The application inventory (`app_constants`) gives ONE name per file — the
    # one the autoloader expects by the path. And this tree holds a 735 KB file
    # with ninety-two modules in it, and those are exactly what gets referenced.
    # So the second check goes by the owners of the declarations (`def.owner`):
    # that is what the file declares.
    #
    # The kind is called `const_ref` rather than `const`: in the first version of
    # this query a mistake in the kind name declared 272 files to be removal
    # candidates, including the largest file of the application. Caught by eye
    # rather than by a check.
    #
    # Rails includes helpers IMPLICITLY: nothing ever calls them by name, and
    # they must not go into the removal candidates.
    #
    # The comments stand HERE rather than inside the query: `.squish` glues the
    # lines into one, and `--` kills everything to the right of it. That is
    # exactly what broke the first version of this query the same day.
    outside = conn.select_all(<<~SQL.squish).to_a
      with out_of_graph as (
        select f.path, f.bytes from code_files f
        where f.path like 'app/%' and not exists (select 1 from v_reach r where r.path = f.path))
      select o.path, o.bytes,
             (select string_agg(a.constant, ', ' order by a.constant)
              from app_constants a where a.path = o.path) as constants,
             exists (select 1 from v_view_used u where u.path = o.path) as drawn,
             (exists (select 1 from app_constants a join code_refs r
                        on r.kind = 'const_ref' and r.token = a.constant
                      where a.path = o.path)
              or exists (select 1 from code_refs d join code_refs r
                           on r.kind = 'const_ref' and r.token = d.owner
                         where d.path = o.path and d.kind = 'def' and d.owner <> '')) as referenced,
             o.path like 'app/helpers/%' as implicit
      from out_of_graph o
      order by o.path
    SQL
    next if outside.empty?

    truthy = ->(value) { value == true || value == 't' }
    js, rest = outside.partition { |row| row['path'].start_with?('app/javascript/') }
    drawn, rest = rest.partition { |row| truthy.call(row['drawn']) }
    views, code = rest.partition { |row| row['path'].start_with?('app/views/') }
    implicit, code = code.partition { |row| truthy.call(row['implicit']) }
    referenced, code = code.partition { |row| truthy.call(row['referenced']) }
    # A file with no constant in the application inventory: there is nothing to
    # search for, and calling it a removal candidate is not allowed — that is a
    # different kind of ignorance.
    nameless, orphan = code.partition { |row| row['constants'].blank? }

    puts
    puts "== файлы приложения вне графа ссылок: #{outside.size} =="
    puts format('   %-44s %4d — недобор ГРАФА: имя шаблона собирается на лету',
                'рисовались в бою, а граф их не видит:', drawn.size)
    # The caveat about the window comes FROM THE DATA rather than from memory: a
    # hard-coded "a day" outlived the window's growth to eleven days and asserted
    # an untruth right next to the number.
    view_window = conn.select_one('select count(distinct day)::int as days from view_runtime') || {}
    puts format('   %-44s %4d — окно наблюдения %s, отсутствие это подозрение',
                'шаблоны, в логах не видели:', views.size,
                view_window['days'].to_i.positive? ? xref_days(view_window['days']) : 'пустое')
    # The reachability of JavaScript is computed by ITS OWN import graph (it is
    # in the graph, the `import` edges), so these files are not "an unparsed
    # layer" but build roots and standalone scripts: nothing imports them by
    # construction.
    puts format('   %-44s %4d — корни сборки и скрипты; разряды в bin/xref js', 'javascript:', js.size)
    puts format('   %-44s %4d — достижимы разве что динамически',
                'ссылка по имени есть, пути нет:', referenced.size)
    puts format('   %-44s %4d — Rails подключает их неявно, по имени не зовут никогда',
                'хелперы:', implicit.size)
    puts format('   %-44s %4d — имени в описи нет, искать нечем', 'без константы:', nameless.size)
    puts format('   %-44s %4d — КАНДИДАТЫ НА СНЯТИЕ', 'ни одной ссылки по имени:', orphan.size)

    if orphan.any?
      puts
      puts "-- ни одной ссылки по имени: #{orphan.size}, крупнейшие ="
      puts '   перед снятием — `bin/xref callers <файл>`: упоминание вне вызова'
      puts '   (спека, опись, документ) держит файл так же, как вызов'
      orphan.sort_by { |row| -row['bytes'].to_i }.first(12).each do |row|
        puts format('  %-58s %7d байт  %s', row['path'], row['bytes'].to_i, row['constants'].to_s[0, 40])
      end
    end
    if drawn.any?
      puts
      puts "-- рисовались в бою, а в графе их нет: #{drawn.size} (это недобор графа, не смерть)"
      drawn.first(6).each { |row| puts "  #{row['path']}" }
    end
  end

  desc 'Откуда берётся значение колонки: bin/xref lineage NAME=search_index.name'
  task lineage: :environment do
    xref_fresh!
    name = xref_arg('NAME').presence or abort 'нужен NAME=<таблица.колонка>'
    conn = Xref::Store.conn
    abort 'имя вида таблица.колонка' unless name.include?('.')

    # The chain upwards: where a value arrives from, and where THAT value
    # arrives from. The depth is limited: chains do hold cycles (two tables
    # feeding each other).
    rows = conn.select_all(<<~SQL.squish).to_a
      with recursive up (depth, target, source, via, path, lines) as (
        select 1, table_name || '.' || column_name, source, via, path, lines
        from v_column_lineage
        where table_name || '.' || column_name = #{conn.quote(name)}
        union all
        select u.depth + 1, l.table_name || '.' || l.column_name, l.source, l.via, l.path, l.lines
        from up u
        join v_column_lineage l on l.table_name || '.' || l.column_name = u.source
        where u.depth < 6 and u.source <> u.target
      )
      select depth, target, source, via, path, array_to_string(lines, ',') as lines
      from up order by depth, target, source
    SQL

    if rows.empty?
      puts "== #{name}: источника в разобранном SQL не нашлось =="
      puts '   значение либо считается на месте, либо приезжает путём, которого'
      puts '   индекс не видит: вставка списком полей, hbase, код вне этого дерева'
      xref_zero_note('ответ')
      next
    end

    puts "== откуда берётся #{name} =="
    rows.each do |row|
      puts format('  %s%-34s <- %-34s %-14s %s:%s', '  ' * (row['depth'].to_i - 1),
                  row['target'], row['source'], row['via'], row['path'], row['lines'])
    end

    # And back the other way: whom this column feeds.
    down = conn.select_all(<<~SQL.squish).to_a
      select table_name || '.' || column_name as target, via, path, array_to_string(lines, ',') as lines
      from v_column_lineage where source = #{conn.quote(name)} order by 1
    SQL
    if down.any?
      puts
      puts "== кого питает #{name}: #{down.size} =="
      down.first(20).each { |r| puts format('  %-34s %-14s %s:%s', r['target'], r['via'], r['path'], r['lines']) }
    end
  end

  # The classes of a file for answering a text search.
  #
  # The order of CHECKING and the order of SHOWING are different, and they must
  # not be confused. Checking has to go from the specific to the general: a
  # template lies in `app/`, and without that it would be recognised as "code".
  # Showing goes from the important to the secondary: the question "where is
  # this" is answered by the code, while specs and documents merely mention it,
  # and if they come first the answer starts with noise.
  XREF_FIND_ORDER = %w[код шаблон настройка база скрипт спека документ прочее].freeze
  # How many files to ask the index about. Eight per class are shown, that is,
  # no more than eighty; with room to spare for sorting within a class.
  XREF_FIND_FACTS = 300
  XREF_FIND_KINDS = [
    ['спека',     %r{\Aspec/}],
    ['документ',  %r{\Adoc/|\.md\z|\A\.claude/}],
    ['шаблон',    %r{\Aapp/views/|\.(erb|haml|slim|builder|jbuilder)\z}],
    ['скрипт',    %r{\Ascript/|\Ascripts/|\Alib/tasks/|\.sh\z}],
    ['настройка', %r{\Aconfig/|\.(yml|yaml|json|conf)\z}],
    ['код',       %r{\Aapp/|\Alib/}],
    ['база',      %r{\Adb/}]
  ].freeze

  def xref_find_kind(path)
    XREF_FIND_KINDS.find { |_name, regexp| path.match?(regexp) }&.first || 'прочее'
  end

  desc 'Таблицы стилей: что объявлено, что подключено, что не действует (bin/xref css)'
  task css: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    totals = conn.select_one(<<~SQL.squish)
      select (select count(*) from v_css_file)::int as files,
             (select sum(bytes) from v_css_file)::bigint as bytes,
             (select count(distinct name) from v_css_class)::int as classes,
             (select count(distinct name) from v_css_class_use)::int as used,
             (select count(*) from v_css_class_pattern)::int as patterns,
             (select count(*) from v_css_blind)::int as blind,
             (select count(*) from code_refs where kind = 'css_import_missing')::int as missing,
             (select count(*) from code_refs where kind = 'css_package')::int as packages
    SQL
    puts format('== таблицы стилей: %d файлов на %s, классов объявлено %d ==',
                totals['files'], ActiveSupport::NumberHelper.number_to_human_size(totals['bytes']),
                totals['classes'])
    puts format('   разметка и код поминают %d классов, узоров имени %d', totals['used'], totals['patterns'])
    # THE BLINDNESS OF THIS LAYER goes next to every answer of the form "the
    # class is not needed", otherwise the answer reads as a verdict. In this tree
    # class names are assembled all the time.
    puts format('  ! имя класса собрано ЦЕЛИКОМ в %d местах — про них слой не знает ничего', totals['blind'])
    puts format('   %d @import ведут в ПАКЕТ (tailwind, bootstrap) — их содержимое не читается',
                totals['packages']) if totals['packages'].to_i.positive?
    puts format('  ! %d @import ведут в никуда', totals['missing']) if totals['missing'].to_i.positive?

    unreach = conn.select_all(<<~SQL.squish).to_a
      select kind, count(*)::int as n, coalesce(sum(bytes), 0)::bigint as bytes from v_css_unreachable
      group by 1 order by 2 desc
    SQL
    puts
    puts '== чем файл стилей жив =='
    unreach.each do |row|
      puts format('  %-26s %3d  %s', row['kind'], row['n'],
                  ActiveSupport::NumberHelper.number_to_human_size(row['bytes']))
    end
    dead = conn.select_all(<<~SQL.squish).to_a
      select path, bytes, classes from v_css_unreachable
      where kind = 'КАНДИДАТ НА СНЯТИЕ' and #{Xref::Verdicts.filter_sql('css_file')}
      order by bytes desc
    SQL
    if dead.any?
      puts
      puts "== таблицу стилей не подключает никто: #{dead.size} =="
      puts '   путь, собранный в конфиге сборки из частей, тоже считается подключением —'
      puts '   иначе живой файл выглядит мёртвым (проверено на site_pages_tw.css)'
      dead.each do |row|
        puts format('  %-56s %-9s классов %d', row['path'][0, 56],
                    ActiveSupport::NumberHelper.number_to_human_size(row['bytes']), row['classes'])
      end
      xref_verdict_note('css_file')
    end

    verdicts = conn.select_all('select verdict, count(*)::int as n from v_css_class_usage group by 1 order by 2 desc').to_a
    puts
    puts '== классы: поминают или нет =='
    verdicts.each { |row| puts format('  %-30s %5d', row['verdict'], row['n']) }
    puts '   «подходит под узор» — имя собрано в разметке, но буквенная часть совпала:'
    puts '   это не доказательство использования, но и не повод снимать'

    nobody = conn.select_all(<<~SQL.squish).to_a
      select name, declared_in from v_css_class_usage
      where verdict = 'НЕ ПОМИНАЕТ НИКТО' and #{Xref::Verdicts.filter_sql('css_class')}
      order by declared_in, name limit 25
    SQL
    if nobody.any?
      total_nobody = conn.select_value("select count(*) from v_css_class_usage where verdict = 'НЕ ПОМИНАЕТ НИКТО'").to_i
      puts
      puts "== класс объявлен, а не поминает никто: #{total_nobody} =="
      # BY FILES — that way it is a decision, while by names it is a list five
      # screens long. A file almost none of whose classes are mentioned is
      # removed entirely: here that is a compatibility shim that outlived its
      # need.
      by_file = conn.select_all(<<~SQL.squish).to_a
        select u.declared_in,
               count(*) filter (where u.verdict = 'НЕ ПОМИНАЕТ НИКТО')::int as nobody,
               count(*)::int as total
        from v_css_class_usage u group by 1
        having count(*) filter (where u.verdict = 'НЕ ПОМИНАЕТ НИКТО') > 0
        order by 2 desc limit 10
      SQL
      by_file.each do |row|
        puts format('  %-52s %4d из %4d', row['declared_in'].to_s.sub('app/javascript/', '')[0, 52],
                    row['nobody'], row['total'])
      end
      puts '   первые имена для глаз:'
      nobody.first(8).each { |row| puts format('      %-34s %s', row['name'][0, 34], row['declared_in'].sub('app/javascript/', '')) }
      xref_verdict_note('css_class')
    end

    # The contour question: not "is the class dead" but "does it work HERE".
    contours = conn.select_all(<<~SQL.squish).to_a
      select contour, verdict, count(*)::int as n from v_css_class_contour
      where contour in (select distinct contour from v_pack_ref)
      group by 1, 2 order by 1, 3 desc
    SQL
    if contours.any?
      puts
      puts '== есть ли правило для класса В ЭТОМ КОНТУРЕ =='
      puts '   вопрос не про мёртвость: класс бывает жив в одном контуре и ничего не делает в другом.'
      puts '   Контур берётся только ДОКАЗУЕМЫЙ: макет своего имени называет пак, пак — вход сборки.'
      puts '   Стили из node_modules (bootstrap, tailwind) индекс не читает — класс библиотеки'
      puts '   попадёт в разряд «правила нет ни в одном НАШЕМ стиле», и это не приговор'
      contours.group_by { |row| row['contour'] }.each do |contour, rows|
        puts format('  %-18s %s', contour, rows.map { |row| "#{row['verdict']}: #{row['n']}" }.join(', '))
      end
      outside = conn.select_value(<<~SQL.squish).to_i
        select count(distinct r.token) from code_refs r
        where r.kind = 'html_class' and r.path like 'app/views/%'
          and split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1)
              not in (select contour from v_pack_ref where path like 'app/views/layouts/%')
      SQL
      puts format('  %-18s %d классов — макет выбирается на ходу, цепочка не доказуема',
                  'вне контуров', outside)
      # THE FILE the rule lies in is printed alongside — without it the answer
      # is unreadable: `gap-2` in `utils.css` means "our utility shim is
      # not included in this contour", and that is an entirely different decision
      # from "the class is dead".
      orphan = conn.select_all(<<~SQL.squish).to_a
        select c.contour, c.name, c.templates,
               (select min(d.path) from v_css_class d where d.name = c.name) as declared_in
        from v_css_class_contour c
        where c.verdict = 'правило есть, но в другом контуре'
        order by c.templates desc, c.contour, c.name limit 12
      SQL
      if orphan.any?
        puts '   самые частые, где правила в контуре нет:'
        orphan.each do |row|
          puts format('      %-14s %-24s в %3d шаблонах  правило в %s',
                      row['contour'], row['name'][0, 24], row['templates'],
                      row['declared_in'].to_s.sub('app/javascript/', ''))
        end
      end
    end
    xref_zero_note('раздел') if totals['classes'].to_i.zero?
  end

  desc 'Javascript и Stimulus: связка шаблон→контроллер→метод, модули, мёртвое (bin/xref js)'
  task js: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    totals = conn.select_one(<<~SQL.squish)
      select (select count(*) from code_files where lang = 'js')::int as files,
             (select count(distinct r.path) from v_reach r join code_files f on f.path = r.path
               where f.lang = 'js')::int as reachable,
             (select count(distinct to_path) from v_js_edges)::int as imported,
             (select count(*) from v_stimulus_registry)::int as registered,
             (select count(distinct identifier) from v_stimulus_use)::int as used,
             (select count(distinct path) from v_stimulus_use)::int as templates,
             (select count(*) from v_stimulus_action)::int as actions,
             (select count(*) from code_refs where kind = 'js_import')::int as imports,
             (select count(distinct token) from code_refs where kind = 'js_package')::int as packages
    SQL
    # TWO DIFFERENT NUMBERS, and they must not be confused: "the import leads"
    # is one step along the import edges, "reachable from an entry point" is a
    # walk of the whole graph. Previously one was printed under the name of the
    # other, and it was counted by the `.js` extension — so in a TypeScript
    # project it was ALWAYS zero (a second project, 2026-10-09).
    puts format('== javascript: %d файлов, импорт ведёт в %d, достижимо от точки входа %d, пакетов извне %d ==',
                totals['files'], totals['imported'], totals['reachable'], totals['packages'])
    puts format('   Stimulus: зарегистрировано %d контроллеров, включает %d в %d шаблонах, действий %d',
                totals['registered'], totals['used'], totals['templates'], totals['actions'])

    # FIRST — what does not fail but simply does not work. Stimulus silently
    # ignores an unknown controller name and a non-existent method: a human
    # clicks and nothing happens.
    broken_use = conn.select_all(<<~SQL.squish).to_a
      select path, identifier, lines[1] as line from v_stimulus_use
      where not registered and #{Xref::Verdicts.filter_sql('stimulus_use')}
      order by identifier, path limit 20
    SQL
    puts
    puts "== шаблон включает НЕзарегистрированный контроллер: #{broken_use.size} =="
    if broken_use.empty?
      puts '   ни одного: Stimulus молча пропускает неизвестное имя, и такое место'
      puts '   выглядело бы работающим — проверено по реестру, а не по совпадению имён'
    else
      broken_use.each { |r| puts format('  %-30s %s:%s', r['identifier'], r['path'][0, 48], r['line']) }
    end
    xref_verdict_note('stimulus_use')

    bad_actions = conn.select_all(<<~SQL.squish).to_a
      select path, identifier, method, verdict, lines[1] as line from v_stimulus_action
      where verdict <> 'метод есть' and #{Xref::Verdicts.filter_sql('stimulus_action')}
      order by verdict, identifier limit 20
    SQL
    puts
    puts "== действие указывает на метод, которого нет: #{bad_actions.size} =="
    if bad_actions.empty?
      puts "   ни одного из #{totals['actions']}: каждое действие сверено с методами своего класса"
    else
      bad_actions.each do |r|
        puts format('  %-22s#%-20s %-28s %s:%s', r['identifier'], r['method'], r['verdict'],
                    r['path'][0, 40], r['line'])
      end
    end
    xref_verdict_note('stimulus_action')

    # Targets come in three classes, and two of the three are not defects.
    # Without the split the report would issue 113 findings where there are none.
    targets = conn.select_all(<<~SQL.squish).to_a
      select verdict, count(*)::int as n from v_stimulus_target group by 1 order by 2 desc
    SQL
    puts
    puts '== цели из разметки =='
    targets.each { |r| puts format('  %-30s %4d', r['verdict'], r['n']) }
    puts '   «не Stimulus» — это чужие атрибуты вида data-bs-target, «селектор» —'
    puts '   значение вроде `#birthday_div`: такой атрибут контроллер читает сам'

    orphan = conn.select_all(<<~SQL.squish).to_a
      select identifier, class_name, methods, targets, values_declared, source
      from v_stimulus_registry
      where templates = 0 and #{Xref::Verdicts.filter_sql('stimulus_orphan')}
      order by identifier
    SQL
    if orphan.any?
      puts
      puts "== контроллер зарегистрирован, а ни один шаблон его не включает: #{orphan.size} =="
      puts '   он попадает в пакет и грузится в браузер, но не активируется нигде'
      orphan.each do |r|
        puts format('  %-24s методов %2d, целей %d, значений %d  %s', r['identifier'], r['methods'],
                    r['targets'], r['values_declared'], r['source'].to_s[0, 44])
      end
    end
    xref_verdict_note('stimulus_orphan')

    # A value with no default that the markup does not set is always empty. For a
    # value WITH a default that is normal, so the classes are kept apart.
    values = conn.select_all(<<~SQL.squish).to_a
      with decl as (select d.path, d.token as name, d.owner as has_default,
                           lower(regexp_replace(d.token, '([A-Z])', '-\\1', 'g')) as kebab
                    from code_refs d where d.kind = 'stimulus_value'),
      used as (select distinct token as middle from code_refs where kind = 'stimulus_value_use')
      select d.path, d.name from decl d
      where d.has_default <> 'default'
        and not exists (select 1 from used u where u.middle like '%-' || d.kebab or u.middle = d.kebab)
      order by d.path, d.name limit 20
    SQL
    if values.any?
      puts
      puts "== значение объявлено без умолчания, а разметка его не задаёт: #{values.size} =="
      puts '   такое значение всегда пустое. У значений С умолчанием это норма и в счёт не идёт'
      values.each { |r| puts format('  %-26s %s', r['name'], r['path'].sub('app/javascript/controllers/', '')) }
    end

    # Modules and the unreachable — with classes: build roots and standalone
    # scripts are imported by nobody BY CONSTRUCTION.
    unreachable = conn.select_all(<<~SQL.squish).to_a
      select kind, count(*)::int as n, coalesce(sum(bytes), 0)::bigint as bytes
      from v_js_unreachable group by 1 order by 2 desc
    SQL
    puts
    puts '== файлы, до которых не дотягивается ни один импорт =='
    unreachable.each do |r|
      puts format('  %-26s %4d  %s', r['kind'], r['n'], ActiveSupport::NumberHelper.number_to_human_size(r['bytes']))
    end
    missing = conn.select_all(<<~SQL.squish).to_a
      select path, token, lines[1] as line from code_refs
      where kind = 'js_import_missing' and #{Xref::Verdicts.filter_sql('js_import')}
      order by path limit 10
    SQL
    if missing.any?
      puts
      puts "== импорт ведёт в никуда: #{missing.size} =="
      missing.each { |r| puts format('  %-50s → %s', "#{r['path']}:#{r['line']}"[0, 50], r['token']) }
    end
    xref_verdict_note('js_import')

    # TOP-LEVEL FUNCTIONS. The classes are mandatory: an exported function may be
    # called by another file, and "nothing calls it" about such a one is only
    # about this tree.
    funcs = conn.select_one(<<~SQL.squish)
      select (select count(*) from v_js_func)::int as total,
             (select count(*) from v_js_func_unused)::int as unused,
             (select count(*) from v_js_func_unused where exported)::int as exported,
             (select count(*) from v_js_func_unused
               where file_kind = 'КАНДИДАТ НА СНЯТИЕ')::int as in_dead_file
    SQL
    puts
    puts format('== функции верхнего уровня: %d, не зовёт никто %d ==', funcs['total'], funcs['unused'])
    puts format('   из них экспортированы %d (их может звать другой файл — это не смерть),', funcs['exported'])
    puts format('   в файлах, до которых не доходит импорт: %d', funcs['in_dead_file'])
    puts '   вызов считается ПО ИМЕНИ: имя — плохой ключ, и это зацепка, а не факт'
    # A FUNCTION IS PASSED AS A VALUE, and that is as much a way of calling it:
    # `setTimeout(tick, 120)`, `{ install: installCityAutocomplete }`. The parse
    # sees only `name(`, so the candidates have to be sifted with a text search —
    # exactly like symbols in Ruby (`before_action :x`). Without that step BOTH
    # of the first two verified findings turned out false.
    candidates = conn.select_all(<<~SQL.squish).to_a
      select path, name from v_js_func_unused
      where not exported and coalesce(file_kind, '') <> 'КАНДИДАТ НА СНЯТИЕ'
      order by path, name
    SQL
    if candidates.any?
      names = candidates.map { |row| row['name'] }.uniq
      mentioned = Hash.new(0)
      begin
        # The search has to cover THE WHOLE TREE: I first limited it to `app/`
        # while the functions are also declared in `script/` — their mentions
        # "were not found" through the fault of the measurement itself, and 335
        # candidates read as dead.
        Xref::TextSearch.lines(names.map { |name| Regexp.escape(name) }.join('|'),
                               word: true, limit: 200_000).each do |hit|
          names.each { |name| mentioned[name] += 1 if hit.text.match?(/(?<![.\w$])#{Regexp.escape(name)}(?![\w$])/) }
        end
      rescue StandardError => e
        puts "   ! просеять кандидатов поиском не удалось: #{e.message[0, 80]}"
      end
      # A declaration of its own is one mention; more than one means the name is
      # named somewhere else, and the function must not be called "dead".
      dead_funcs = candidates.reject { |row| mentioned[row['name']].to_i > 1 }
      # A CLASS BY PLACE, as with columns and queries: in a one-off audit script
      # an unused helper function is normal, while in the application it is a
      # finding. Mixing them means drowning the second in the first.
      by_place = dead_funcs.group_by do |row|
        case row['path']
        when %r{\Aapp/} then 'приложение'
        when %r{\Aspec/} then 'спека'
        else 'скрипт'
        end
      end
      puts format('   не зовётся и нигде не поминается: %d из %d кандидатов — %s',
                  dead_funcs.size, candidates.size,
                  by_place.map { |place, rows| "#{place} #{rows.size}" }.join(', '))
      puts '   (остальные передают значением — `setTimeout(tick)`, `{ install: fn }`)'
      Array(by_place['приложение']).first(15).each do |row|
        puts format('      %-34s %s', row['name'][0, 34], row['path'].sub('app/javascript/', ''))
      end
      if Array(by_place['приложение']).size > 15
        puts "      … и ещё #{by_place['приложение'].size - 15} в приложении"
      end
    end

    # LIBRARIES: we do not go inside, we count the calls.
    # THE APPLICATION ONLY: the scripts and the specs hold test drivers and
    # node:fs, and the question "what to throw out of the bundle" is not about
    # them.
    packages = conn.select_all(<<~SQL.squish).to_a
      select b.owner as package, count(distinct b.path)::int as files,
             sum((b.detail->>'mentions')::int)::int as mentions,
             array_to_string((array_agg(distinct b.token order by b.token))[1:3], ', ') as sample
      from code_refs b
      where b.kind = 'js_binding' and b.owner <> '' and b.path like 'app/%'
        and b.owner not like '.%' and b.owner not like '/%'
      group by 1 order by 3 desc, 2 desc limit 12
    SQL
    if packages.any?
      puts
      puts '== библиотеки: зовут ли их ещё =='
      puts '   внутрь библиотеки индекс не лезет: там «неиспользуемого» большинство по'
      puts '   построению, и выкидывают её версией. Считаются ВЫЗОВЫ через привязки импорта'
      packages.each do |row|
        puts format('  %-34s в %2d файлах, упоминаний привязок %4d  %s',
                    row['package'][0, 34], row['files'], row['mentions'], row['sample'].to_s[0, 30])
      end
      # A LIBRARY AS A GLOBAL: `$(...)` with no import. It has no bindings, so
      # the previous count does not see it at all, while the question "can jQuery
      # be thrown out yet" is the most valuable one in this section.
      globals = conn.select_all(<<~SQL.squish).to_a
        select token as name, count(distinct path)::int as files,
               sum(array_length(lines, 1))::int as places
        from code_refs
        where kind = 'js_call' and token in ('$', 'jQuery', '_', 'moment', 'Swiper')
          and path like 'app/%' and path not like '%/vendor/%'
          and not exists (select 1 from code_refs b where b.kind = 'js_binding' and b.token = code_refs.token)
        group by 1 order by 3 desc
      SQL
      if globals.any?
        puts '   доступ ГЛОБАЛОМ, без импорта (привязок нет, поэтому выше их не видно):'
        globals.each do |row|
          puts format('      %-12s в %d файлах, %d мест', row['name'], row['files'], row['places'])
        end
      end
      quiet = conn.select_all(<<~SQL.squish).to_a
        select b.owner as package, count(distinct b.path)::int as files
        from code_refs b
        where b.kind = 'js_binding' and b.owner <> '' and b.path like 'app/%'
          and b.owner not like '.%' and b.owner not like '/%'
        group by 1 having sum((b.detail->>'mentions')::int) <= count(distinct b.path) order by 1
      SQL
      if quiet.any?
        puts '   привязку не поминают нигде, кроме самого импорта:'
        quiet.each { |row| puts format('      %-34s в %d файлах', row['package'][0, 34], row['files']) }
      end
    end

    dynamic = conn.select_value("select count(*) from code_refs where kind = 'stimulus_dynamic'").to_i
    puts
    puts '== чем этот ответ неполон =='
    puts "  ! имя контроллера или цели собрано подстановкой в #{dynamic} местах — связь там не прослежена" if dynamic.positive?
    # Attachment is parsed from three places, and the report lists them with
    # numbers: otherwise the reader does not know how much "nothing attaches it"
    # can be trusted.
    sources = conn.select_one(<<~SQL.squish)
      select count(distinct token) filter (where owner = 'js')::int as from_js,
             count(distinct token) filter (where path like '%.rb')::int as from_ruby,
             count(distinct token) filter (where owner <> 'js' and path not like '%.rb')::int as from_markup
      from code_refs where kind = 'stimulus_use'
    SQL
    puts format('  . включение разбирается из трёх мест: разметка (%d имён), помощники на ruby (%d),',
                sources['from_markup'], sources['from_ruby'])
    puts format('    и код на ходу через dataset.controller/setAttribute (%d). Остаётся имя, собранное на лету',
                sources['from_js'])
    puts '  ! методы, унаследованные от базового класса, считаются по файлу самого класса'
    xref_zero_note('раздел') if totals['registered'].to_i.zero?
  end

  desc 'Фронт и службы: конфигурация nginx/angie, состав служб, опасные места в скриптах (bin/xref front)'
  task front: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    # THE DEFECTS FIRST. In a front-end config an error does not fail — it
    # quietly starts serving the wrong thing, and each of the four rules here
    # stands for an incident.
    defects = conn.select_all(<<~SQL.squish).to_a
      select path, defect, detail, rule, lines[1] as line from v_conf_defect
      where #{Xref::Verdicts.filter_sql('front')} order by path, line
    SQL
    puts "== дефекты конфигурации фронта: #{defects.size} =="
    if defects.empty?
      xref_zero_note('раздел') unless xref_verdict_note('front')
    else
      puts '   ни один из них не роняет конфиг: он просто начинает отдавать не то'
      defects.each do |r|
        puts format('  %-58s %s', "#{r['path']}:#{r['line']}"[0, 58], r['defect'])
        puts format('      %s', r['detail'].to_s[0, 100])
        puts format('      правило: %s', r['rule'].to_s[0, 100]) if r['rule'].present?
      end
      xref_verdict_note('front')
    end

    files = conn.select_all(<<~SQL.squish).to_a
      select path,
             count(*) filter (where kind = 'conf_block')::int as blocks,
             count(*) filter (where kind = 'conf_directive')::int as directives
      from code_refs where kind in ('conf_block', 'conf_directive') group by 1 order by 1
    SQL
    if files.any?
      puts
      puts "== разобранные конфиги фронта: #{files.size} =="
      files.each { |r| puts format('  %-52s блоков %2d, директив %3d', r['path'][0, 52], r['blocks'], r['directives']) }
    end

    # Locations with their paths: "which virtual host serves this URL" is a
    # question that had no answer at all before the configs were parsed.
    locations = conn.select_all(<<~SQL.squish).to_a
      select b.path, b.args as location, b.lines[1] as line,
             (select string_agg(distinct d.directive, ', ' order by d.directive)
              from v_conf_directive d
              where d.path = b.path and d.scope like '%' || b.args || '%'
                and d.directive in ('proxy_pass', 'try_files', 'return', 'root', 'alias')) as serves
      from v_conf_block b where b.block = 'location' order by b.path, b.lines[1] limit 30
    SQL
    if locations.any?
      puts
      puts "== локации: #{locations.size} =="
      locations.each do |r|
        puts format('  %-30s %-28s %s', File.basename(r['path'])[0, 30], r['location'].to_s[0, 28],
                    r['serves'].to_s[0, 40])
      end
    end

    services = conn.select_all(<<~SQL.squish).to_a
      select s.path, s.service, s.image,
             (select count(*) from v_compose_detail d
              where d.path = s.path and d.service = s.service and d.what = 'ключ среды')::int as env,
             (select count(*) from v_compose_detail d
              where d.path = s.path and d.service = s.service and d.what = 'монтирование')::int as mounts,
             (select string_agg(d.value, ', ') from v_compose_detail d
              where d.path = s.path and d.service = s.service and d.what = 'порт') as ports
      from v_compose_service s order by s.path, s.service
    SQL
    if services.any?
      puts
      puts "== службы, КАК ОБЪЯВЛЕНЫ: #{services.size} =="
      puts '   это объявление, а не работающий состав — его показывает bin/xref places'
      services.each do |r|
        # The file is ALWAYS printed: one service is declared in two files (the
        # ordinary one and the orchestrator one), and without the file name the
        # two lines read as a duplicate.
        puts format('  %-22s %-30s %s', r['service'].to_s[0, 22], r['image'].to_s[0, 30],
                    File.basename(r['path']).delete_prefix('docker-compose.')[0, 34])
        puts format('      ключей среды %2d, монтирований %d%s', r['env'], r['mounts'],
                    r['ports'].present? ? ", порты #{r['ports']}" : '')
      end
    end

    # The dangerous places in scripts are a list FOR THE EYE rather than a
    # warning from the tool: a recursive removal in this tree is worth knowing by
    # name.
    risky = conn.select_all(<<~SQL.squish).to_a
      select path, line_text, lines[1] as line from v_sh_dangerous
      where #{Xref::Verdicts.filter_sql('script')} order by path, line limit 25
    SQL
    total_risky = conn.select_value("select count(*) from v_sh_dangerous
                                     where #{Xref::Verdicts.filter_sql('script')}").to_i
    if risky.any?
      puts
      puts "== в скриптах: снос, перезапись, права — #{total_risky} мест =="
      puts '   это список для глаз, а не приговор: у половины стоит ловушка на выход'
      risky.each { |r| puts format('  %-44s %s', "#{r['path']}:#{r['line']}"[0, 44], r['line_text'].to_s[0, 76]) }
      puts "   … и ещё #{total_risky - risky.size}" if total_risky > risky.size
    end
    xref_verdict_note('script')

    commands = conn.select_all(<<~SQL.squish).to_a
      select command, count(distinct path)::int as files, coalesce(sum(count), 0)::int as places
      from v_sh_command group by 1 order by 3 desc
    SQL
    if commands.any?
      puts
      puts '== чем скрипты ходят наружу =='
      commands.each { |r| puts format('  %-20s в %2d файлах, %3d мест', r['command'], r['files'], r['places']) }
    end
    xref_zero_note('раздел') if commands.empty?
  end

  desc 'Документация как слой индекса: битые ссылки, устаревшие имена, сломанные примеры (bin/xref docs)'
  task docs: :environment do
    xref_fresh!
    conn = Xref::Store.conn

    totals = conn.select_one(<<~SQL.squish)
      select (select count(*) from code_files where lang = 'markdown')::int as docs,
             (select count(*) from v_doc_heading)::int as headings,
             (select count(*) from v_doc_link)::int as links,
             (select count(*) from v_doc_path)::int as paths,
             (select count(*) from v_doc_code)::int as blocks,
             (select count(*) from v_doc_name)::int as names
    SQL
    puts format('== документация: %d файлов, %d разделов, %d ссылок, %d упоминаний путей ==',
                totals['docs'], totals['headings'], totals['links'], totals['paths'])
    puts format('   блоков кода %d, имён из базы названо %d', totals['blocks'], totals['names'])
    puts '   имя считается названным, только если оно в обратных кавычках или в блоке кода:'
    puts '   слова прозы в индекс не идут, иначе ответы утонут во «в таблице ниже»'

    # A link into the void. The classes are printed separately: a link into a
    # working directory (`.log/…`) is expected rather than broken, and mixing
    # them means drowning fifteen real ones in six hundred.
    broken = conn.select_all(<<~SQL.squish).to_a
      select doc, target, lines[1] as line from v_doc_link_broken
      where #{Xref::Verdicts.filter_sql('doc_link')} order by doc, line limit 20
    SQL
    outside = conn.select_value("select count(*) from v_doc_link where kind = 'вне дерева'").to_i
    unwritten = conn.select_value("select count(*) from v_doc_link where kind = 'памятка не написана'").to_i
    puts
    puts "== ссылка ведёт в пустоту: #{broken.size} =="
    if broken.empty?
      xref_zero_note('раздел') unless xref_verdict_note('doc_link')
    else
      broken.each { |r| puts format('  %-58s → %s', "#{r['doc']}:#{r['line']}"[0, 58], r['target'].to_s[0, 60]) }
      xref_verdict_note('doc_link')
    end
    puts "   ещё #{outside} ссылок ведут ВНЕ дерева (`/…`, в основном в рабочий каталог .log) —" if outside.positive?
    puts '   их отсутствие ожидаемо и находкой не считается' if outside.positive?
    puts "   и #{unwritten} вики-ссылок на памятки, которые ещё не написаны — это пометка, а не ошибка" if unwritten.positive?

    # A path named in backticks while the file is absent. The most useful finding
    # of this report: that is how a document ages silently — the file was renamed
    # and the document stayed.
    #
    # A living document against a historical record goes BY ONE rule shared with
    # the finding class (Xref::Verdicts::LIVING_DOC): two spellings would drift
    # apart, and `docs` and `findings` would start answering differently.
    #
    # The comment stands HERE rather than inside the query, and that is not
    # style: `squish` collapses the query into one line and takes everything up
    # to the end into a `--` comment — including the `group by`. Rule 4 of part
    # VII of the guide; caught in this very place.
    stale = conn.select_all(<<~SQL.squish).to_a
      select doc, count(*)::int as places
      from v_doc_path where kind = 'НЕТ ТАКОГО ФАЙЛА'
        and #{Xref::Verdicts.filter_sql('doc_path')}
        and #{Xref::Verdicts::LIVING_DOC}
      group by 1 order by 2 desc limit 12
    SQL
    total_stale = conn.select_value("select count(distinct target) from v_doc_path
                                     where kind = 'НЕТ ТАКОГО ФАЙЛА'
                                       and #{Xref::Verdicts.filter_sql('doc_path')}").to_i
    # A living document against a historical record: in an audit or a journal a
    # stale path is THE TRUTH ABOUT THE PAST and must not be rewritten. The
    # finding is only in what gets read as current.
    split = conn.select_all(<<~SQL.squish).to_a
      select case
               when doc like '.claude/goal-%' then 'цель сессии'
               when doc like 'doc/schema/%' then 'артефакт задачи'
               when doc like 'doc/memory-bank/%' then 'журнал'
               when doc like 'doc/auto/%' then 'машинный отчёт'
               when doc like 'doc/goals-merge-parts/%' then 'разбор плана'
               when doc ~ 'audit|findings|-20[0-9]{6}' then 'аудит с датой'
               else 'ЖИВОЙ ДОКУМЕНТ'
             end as kind,
             count(*)::int as places, count(distinct doc)::int as docs
      from v_doc_path where kind = 'НЕТ ТАКОГО ФАЙЛА'
        and #{Xref::Verdicts.filter_sql('doc_path')}
      group by 1 order by 2 desc
    SQL
    puts
    puts "== документ называет файл, которого нет: #{total_stale} путей =="
    puts '   считается только путь, привязанный к корню дерева (app/, lib/, spec/, …):'
    puts '   наглядный пример в тексте («user_profile.rb») находкой не считается'
    split.each { |r| puts format('   %-18s %5d мест в %d документах', r['kind'], r['places'], r['docs']) }
    puts '   в исторической записи устаревший путь — правда о прошлом: находка только у живых'
    if stale.any?
      puts
      puts '   живые документы, которые читают как действующие:'
      stale.each { |r| puts format('     %-54s %3d путей', r['doc'][0, 54], r['places']) }
      puts '   переписывать их вслепую НЕЛЬЗЯ: совпадение по имени файла даёт ложные'
      puts '   замены (проверено: `payment.js` указал на сценарий playwright), а часть'
      puts '   упоминаний намеренно говорит о снятом'
    end
    xref_verdict_note('doc_path')

    # A table named in the SQL of a document that is in no schema snapshot.
    unknown = conn.select_all(<<~SQL.squish).to_a
      select table_name, docs, in_code, array_to_string(docs_list[1:2], ', ') as sample
      from v_doc_table_unknown where #{Xref::Verdicts.filter_sql('doc_table')}
      order by docs desc, table_name limit 20
    SQL
    if unknown.any?
      puts
      puts "== в запросе документа названа таблица, которой нет в схемах: #{unknown.size} =="
      puts '   это вопрос, а не приговор: так выглядит и снятая таблица, и ещё не созданная.'
      puts '   «трогает код» справа решает: если нет — документ про прошлое или про будущее'
      unknown.each do |r|
        touched = r['in_code'] == true || r['in_code'] == 't'
        puts format('  %-34s в %d документах  %-18s %s', r['table_name'].to_s[0, 34], r['docs'],
                    touched ? 'КОД ЕЁ ТРОГАЕТ' : 'код не трогает', r['sample'].to_s[0, 44])
      end
    end
    xref_verdict_note('doc_table')

    # Code examples. The classes are the main thing: without them "did not
    # parse" was a false alarm over 137 blocks, of which fourteen turned out
    # real.
    verdicts = conn.select_all(<<~SQL.squish).to_a
      select verdict, count(*)::int as n from v_doc_code group by 1 order by 2 desc
    SQL
    puts
    puts '== блоки кода в документах: разобраны теми же разборщиками, что файлы =='
    verdicts.each { |r| puts format('  %-18s %5d', r['verdict'], r['n']) }
    puts '   набросок — с человеческими пропусками (…, <номер ДЦ>), отрывок — оборван посреди'
    puts '   ветвления, заплатка — diff, другой диалект — валидный SQL не постгреса.'
    puts '   Ни один из этих разрядов дефектом примера НЕ является'

    worst = conn.select_all(<<~SQL.squish).to_a
      select doc, lang, detail, lines[1] as line from v_doc_code
      where verdict = 'НЕ РАЗОБРАЛСЯ' and #{Xref::Verdicts.filter_sql('doc_code')}
      order by doc limit 20
    SQL
    if worst.any?
      puts
      puts "== пример, который не разбирается ни одним способом: #{worst.size} =="
      worst.each do |r|
        puts format('  %-58s %-5s %s', "#{r['doc']}:#{r['line']}"[0, 58], r['detail'], r['lang'].to_s[0, 54])
      end
    end
    xref_verdict_note('doc_code')
    # The caveat about a zero only when there is a zero. An unconditional call
    # printed "the section is empty" under a section of seven lines: the fact that
    # an explanation is printed once per run does not make it true anywhere.
    xref_zero_note('раздел') if worst.empty?
  end

  desc 'Поиск по тексту со смыслом индекса: bin/xref find NAME=<образец> [KIND=код] [FIXED=1] [I=1]'
  task find: :environment do
    xref_fresh!
    pattern = (xref_arg('NAME').presence || xref_arg('PATTERN').presence) or abort 'нужен NAME=<образец>'
    conn = Xref::Store.conn

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    hits = Xref::TextSearch.lines(pattern, fixed: ENV['FIXED'].present?,
                                           ignore_case: ENV['I'].present?)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    engine = Xref::TextSearch.tool[1]

    # WHAT THE SEARCH CANNOT SEE AT ALL. A file with a NUL byte inside is binary
    # for `rg` and `git grep`: the first silently returns "not found", the second
    # prints "Binary file … matches" instead of the lines. The index knows such
    # files (the parse reads them) and is obliged to name them — otherwise "does
    # not occur in the tree" is a lie with nothing to catch it.
    blind = conn.select_values('select path from v_search_blind order by path')
    if blind.any?
      puts format('  ! поиск НЕ ВИДИТ %d файлов (NUL-байт внутри, для rg они двоичные): %s',
                  blind.size, blind.first(3).join(', ') + (blind.size > 3 ? ', …' : ''))
      puts '    про них спрашивать bin/xref where / callers — индекс их разобрал'
    end

    if hits.empty?
      puts "«#{pattern}» в дереве не встречается (#{engine}, #{format('%.2f', elapsed)} с)"
      puts '   это ответ про ТЕКСТ. Имя, собранное в коде на лету, по слову не найти —'
      puts "   bin/xref holes и bin/xref where скажут, не тот ли это случай"
      next
    end

    by_path = hits.group_by(&:path)
    kinds = by_path.keys.group_by { |path| xref_find_kind(path) }
                   .transform_values(&:size).sort_by { |_k, n| -n }
    puts format('== «%s»: %d находок в %d файлах (%s, %.2f с) ==',
                pattern, hits.size, by_path.size, engine, elapsed)
    puts "   по разрядам: #{kinds.map { |kind, n| "#{kind} #{n}" }.join(', ')}"
    puts "   находок больше #{Xref::TextSearch::MAX_HITS} — ответ обрезан" if hits.size >= Xref::TextSearch::MAX_HITS

    # HERE IS WHAT GREP DOES NOT KNOW. For every file found: is it reachable from
    # production, which tables it touches, how many unparsed queries it holds, is
    # it rendered in the live logs. One query for all the files at once: by name
    # there can be hundreds of them, and a query per file would turn the answer
    # into a minute.
    # The facts are asked not about every file found but about those that will
    # reach the answer. A pattern like `data-controller` matches in a thousand
    # files, and asking the facts for all thousand cost 7.7 s while answering with
    # eight lines per class.
    asked = by_path.sort_by { |_path, found| -found.size }.first(XREF_FIND_FACTS).to_h.keys
    quoted = asked.map { |p| conn.quote(p) }.join(',')
    # Reachability is computed ONCE: a recursive walk of the graph costs 0.7 s,
    # and as a correlated subquery it was computed for every file found — the
    # report over 28 files answered in 3.4 s instead of one second.
    reach = xref_snapshot('v_reach')
    facts = conn.select_all(<<~SQL.squish).to_a.to_h { |row| [row['path'], row] }
      select f.path, f.lang, f.refs_count,
             (select min(r.depth) from #{reach} r where r.path = f.path) as depth,
             (select string_agg(distinct r.place, ',') from #{reach} r where r.path = f.path) as places,
             (select string_agg(distinct c.token, ', ' order by c.token)
              from (select token from code_refs where path = f.path and kind = 'pg_table'
                    order by count desc limit 4) c) as tables,
             (select count(*) from code_refs b where b.path = f.path
              and b.kind in ('sql_blind', 'hb_dynamic', 'scan_error')) as blind,
             exists (select 1 from v_view_used u where u.path = f.path) as drawn,
             (select count(distinct e.from_path) from v_code_edges e where e.to_path = f.path) as callers
      from code_files f where f.path in (#{quoted})
    SQL

    wanted = ENV['KIND'].presence
    groups = by_path.group_by { |path, _| xref_find_kind(path) }
    shown = 0
    XREF_FIND_ORDER.each do |kind|
      entries = groups[kind]
      next if entries.nil? || (wanted && kind != wanted)

      # Within a class, first what is reachable from production: that is the most
      # valuable.
      entries = entries.sort_by do |path, found|
        [facts.dig(path, 'depth').nil? ? 1 : 0, -found.size, path]
      end
      puts
      puts "== #{kind}: #{entries.size} файлов =="
      entries.first(wanted ? 40 : 8).each do |path, found|
        fact = facts[path] || {}
        marks = []
        marks << if fact['depth']
                   "достижим из #{fact['places']} (глубина #{fact['depth']})"
                 elsif %w[код шаблон].include?(kind)
                   'ВНЕ ГРАФА ссылок'
                 end
        marks << 'рисуется в бою' if fact['drawn'] == true || fact['drawn'] == 't'
        marks << "зовут из #{fact['callers']} файлов" if fact['callers'].to_i.positive?
        marks << "таблицы: #{fact['tables']}" if fact['tables'].present?
        marks << "слепых мест #{fact['blind']}" if fact['blind'].to_i.positive?
        # "Not in the index" is asserted ONLY about a file that was asked about:
        # otherwise the absence of an answer about an unrequested file would read
        # as the absence of the file from the index.
        marks << 'файла нет в индексе' if facts[path].nil? && asked.include?(path)
        puts format('  %-52s %3d  %s', path[0, 52], found.size, marks.compact.join(', ')[0, 74])
        found.first(3).each { |hit| puts format('      %5d  %s', hit.line, hit.text.strip[0, 96]) }
        puts format('      … и ещё %d строк в этом файле', found.size - 3) if found.size > 3
        shown += 1
      end
      puts "   … и ещё #{entries.size - 8} файлов этого разряда (KIND=#{kind})" if !wanted && entries.size > 8
    end

    # The pattern looks like a name from the database — which means there is an
    # answer to this question stronger than a textual one, and staying silent
    # about that is not allowed: a text search yields candidates while parsed SQL
    # yields facts.
    name = pattern.to_s[/[A-Za-z_][A-Za-z0-9_]*/].to_s
    if name.length >= 3
      known = conn.select_one(<<~SQL.squish)
        select exists (select 1 from v_tables where name = #{conn.quote(name)}) as is_table,
               (select count(distinct table_name) from v_columns
                where column_name = #{conn.quote(name)}) as in_tables
      SQL
      if known['is_table'] == true || known['is_table'] == 't'
        puts
        puts "   «#{name}» — таблица в снимках схем: bin/xref where #{name} ответит разобранным SQL,"
        puts '   а не совпадением по слову (имя таблицы бывает и в комментарии, и в чужой строке)'
      elsif known['in_tables'].to_i.positive?
        puts
        puts "   «#{name}» — колонка в #{known['in_tables']} таблицах: bin/xref column #{name}"
      end
    end
    puts
    puts format('   показано файлов: %d из %d. Это поиск по ТЕКСТУ: имя, собранное на лету,', shown, by_path.size)
    puts '   так не находится вовсе — bin/xref holes про такие места'
  end

  desc 'Колонки таблицы: что читается, что пишется, что мертво (TABLE=users)'
  task columns: :environment do
    xref_fresh!
    table = (xref_arg('TABLE').presence || xref_arg('NAME').presence) or abort 'нужен TABLE=<имя таблицы>'
    conn = Xref::Store.conn
    quoted = conn.quote(table)

    rows = conn.select_all(<<~SQL.squish).to_a
      select rw.column_name, rw.types, rw.read_files, rw.write_files, rw.orm_files,
             rw.key_files, rw.key_test_files, rw.key_table_files, rw.db_reads, rw.db_writes,
             coalesce(l.read_lists, 0) as read_lists,
             coalesce(l.write_lists, 0) as write_lists,
             coalesce(l.unknown_lists, 0) as unknown_lists,
             l.names as list_names
      from v_column_rw rw
      left join (
        select column_name,
               count(*) filter (where direction = 'чтение')::int as read_lists,
               count(*) filter (where direction = 'запись')::int as write_lists,
               count(*) filter (where direction not in ('чтение', 'запись'))::int as unknown_lists,
               string_agg(distinct list_name, ', ') as names
        from v_column_via_list group by 1
      ) l on l.column_name = rw.column_name
      where rw.table_name = #{quoted} order by rw.column_name
    SQL
    if rows.empty?
      puts "колонок таблицы #{table} в снимках нет — проверьте имя и bin/xref schema"
      next
    end

    # A table with a rewrite rule: an insert into it may turn out to be an
    # update, and that has to be known before the rest of the report is read.
    rewrite = conn.select_one(<<~SQL.squish)
      select array_to_string(rules, ', ') as rules, array_to_string(events, ', ') as events,
             has_instead, sources
      from v_rewritten_tables where table_name = #{quoted}
    SQL
    if rewrite
      puts "!! у таблицы #{rewrite['sources']} сред с правилами перезаписи: #{rewrite['rules']}"
      puts "   событие: #{rewrite['events']}#{rewrite['has_instead'] ? ', DO INSTEAD' : ''}"
      puts '   вставка в такую таблицу может оказаться обновлением, и колонки,'
      puts '   которые правило увеличивает, оно же и ЧИТАЕТ'
      puts
    end

    star = conn.select_value("select coalesce(sum(count), 0) from code_refs
                              where kind = 'pg_select_star' and owner = #{quoted}").to_i
    star_cover = conn.select_one("select * from v_star_coverage where table_name = #{quoted}")
    blind = conn.select_value(<<~SQL.squish).to_i
      select count(*) from code_refs
      where kind = 'sql_blind' and path in (
        select distinct path from code_refs
        where kind in ('pg_table', 'pg_table_guess') and token = #{quoted}
      )
    SQL

    # THE QUESTION this breakdown answers: "which fields we do not use in the
    # code".
    #
    # A name in a field list is NOT a use. The list is named once and for every
    # column at once: `select #{FIELDS} from …` is evidence about a query rather
    # than about a column. A use of a column that arrived through such a query is
    # when the VALUE is taken by key (`row['member_messenger']`). While that kind did not
    # exist the report answered "the direction was not traced" and hid the
    # answer: nothing takes `member_photo`, while `member_messenger` is taken — in one
    # place, and those are different things.
    def mode(row, pattern: nil)
      read = row['read_files'].to_i.positive? || row['orm_files'].to_i.positive? ||
             row['db_reads'].to_i.positive? || row['key_files'].to_i.positive? ||
             pattern.present?
      write = row['write_files'].to_i.positive? || row['write_lists'].to_i.positive? ||
              row['db_writes'].to_i.positive?
      return 'both' if read && write
      return 'read' if read
      return 'write' if write

      'none'
    end

    # Column names assembled by interpolation: `language$1_2` recognises
    # `locale1_2`…`locale4_2`, and without it eight columns of a series
    # landed in "not used" while they are read in three places.
    #
    # The strength of a pattern decides whether anything can be judged by it. For
    # `$1_$1` the literal part is one character, and it matches 73 columns out of
    # 99: such a pattern proves nothing. Hence:
    #   STRONG (literal part ≥3 and a piece ≥2) — counts as a use;
    #   WEAK — does not move the column into "used", but is printed as a warning
    #   next to the list: the name is assembled in the code, and it has to be
    #   looked at by eye.
    patterns = conn.select_all(<<~SQL.squish).to_a
      select pattern, count(distinct path)::int as files,
             count(distinct path) filter (
               where path not like 'spec/%' and path not like 'script/%')::int as app_files,
             min(path || ':' || lines[1]) as example
      from (select pattern, path, lines from v_column_key_pattern
            union all select pattern, path, lines from v_name_pattern) p
      group by 1
    SQL
    columns_of_table = rows.map { |row| row['column_name'] }
    patterns.each do |row|
      literal = row['pattern'].split('$1', -1)
      row['regexp'] = /\A#{literal.map { |part| Regexp.escape(part) }.join('.+')}\z/
      hits = columns_of_table.count { |name| name.match?(row['regexp']) }
      # Three conditions, each derived from a false positive:
      #   the literal part — otherwise `$1_$1` matches 73 columns out of 99;
      #   SELECTIVITY — `user_$1` catches twenty columns, and proving the use of
      #     ONE by them is not allowed (that is exactly how 13 `user_*` columns
      #     falsely became "used" for me);
      #   not specs only — `"user_#{user_id}"` in three specs is not a column at
      #     all but a login string.
      row['usable'] = literal.join.match?(/[a-z]/i)
      row['strong'] = row['usable'] && literal.sum(&:length) >= 3 &&
                      literal.any? { |part| part.length >= 2 } &&
                      hits <= 4 && row['app_files'].to_i.positive?
    end
    strong_patterns, weak_patterns = patterns.partition { |row| row['strong'] }
    pattern_match = ->(column_name) { strong_patterns.find { |row| column_name.match?(row['regexp']) } }

    groups = rows.group_by { |row| mode(row, pattern: pattern_match.call(row['column_name'])) }
    # The same column on ANOTHER table. `big_users` and `big_users_live` are two
    # copies of the same data, and a column read on the copy is "not used in the
    # code" only formally: one cron selects `a.opt3_6` out of `big_users_live`. That
    # is what the owner caught the answer on.
    siblings = conn.select_all(<<~SQL.squish).to_a.group_by { |row| row['column_name'] }
      select u.column_name, u.table_name, count(distinct u.path)::int as files
      from v_column_usage u
      where u.table_name is not null and u.table_name <> #{quoted} and u.mode = 'чтение'
        and u.column_name in (select column_name from v_column_rw where table_name = #{quoted})
      group by 1, 2 order by 3 desc
    SQL
    sibling_mark = lambda do |column_name|
      list = siblings[column_name].to_a.first(2)
      next nil if list.empty?

      "ту же колонку читают у #{list.map { |row| "#{row['table_name']} (#{row['files']})" }.join(', ')}"
    end

    # Counted only where this table is touched: across the whole tree the number
    # says nothing about this table.
    # Production evidence. Stronger than any static one: the query did not
    # "possibly run", it ran. But the class matters — "named in the selection" in
    # production means exactly what a name in a field list means: the list is
    # selected whole.
    runtime = conn.select_all(<<~SQL.squish).to_a.index_by { |row| row['column_name'] }
      select column_name, coalesce(sum(hits), 0)::bigint as hits, bool_or(filtered) as filtered,
             bool_or(written) as written, max(last_day) as last_day
      from v_runtime_column group by 1
    SQL
    runtime_mark = lambda do |column_name|
      row = runtime[column_name]
      next 'в бою не трогали' if row.nil?

      parts = []
      parts << 'В БОЮ В УСЛОВИИ' if row['filtered'] == true || row['filtered'] == 't'
      parts << 'В БОЮ ПИШУТ' if row['written'] == true || row['written'] == 't'
      parts << "в бою только выбирают (#{row['hits']})" if parts.empty?
      parts.join(', ')
    end
    runtime_day = conn.select_value('select max(day) from sql_runtime')
    window = conn.select_one('select * from v_runtime_window') || {}

    # Accesses by a variable key in the files of this table — three classes, and
    # the difference between them is the answer. Previously the number was one:
    # "so many accesses, the list is overstated by that much". But some of them
    # are now known BY TABLE — and an access to a row of ANOTHER table has
    # nothing to do with this list and is subtracted from the caveat.
    dyn = conn.select_one(<<~SQL.squish)
      select coalesce(sum(count) filter (where table_name = #{quoted}), 0)::int as mine,
             coalesce(sum(count) filter (where table_name is null), 0)::int as unknown,
             coalesce(sum(count) filter (where table_name is not null
                                           and table_name <> #{quoted}), 0)::int as others
      from v_column_key_dynamic
      where path in (select distinct path from code_refs
                     where kind in ('pg_table', 'pg_table_guess') and token = #{quoted})
    SQL
    dynamic = dyn['mine'].to_i + dyn['unknown'].to_i
    puts "== #{table}: #{rows.size} колонок =="
    puts format('   В КОДЕ НЕ ИСПОЛЬЗУЕТСЯ: %d. Читается: %d, пишется: %d, и читается и пишется: %d',
                groups['none'].to_a.size, groups['read'].to_a.size,
                groups['write'].to_a.size, groups['both'].to_a.size)
    if runtime_day
      live = conn.select_one(<<~SQL.squish)
        select coalesce(sum(hits), 0)::bigint as hits, max(last_day) as day,
               coalesce(max(days), 0)::int as days
        from v_runtime_table where table_name = #{quoted}
      SQL
      # The window is printed ALWAYS and alongside: "not touched in production"
      # over one day and over a hundred days are different statements while they
      # look the same.
      if window['days'].to_i < 2
        puts format('   в боевых логах за %s: таблицу трогали %s раз', window['last_day'], live['hits'])
        puts '   окно наблюдения — одни сутки, и «в бою не трогали» значит ровно это:'
        puts '   редкий крон в такое окно не попадает. bin/xref sql собирает ещё день'
      else
        puts format('   в боевых логах (окно %s, %s…%s): таблицу трогали %s раз, видели в %d из %d суток',
                    xref_days(window['days']), window['first_day'], window['last_day'],
                    live['hits'], live['days'], window['days'])
      end
    end

    [['В КОДЕ НЕ ИСПОЛЬЗУЕТСЯ: ни запроса, ни ORM, ни взятия значения по ключу', 'none'],
     ['пишется, но значение не берёт никто', 'write'],
     ['только читается, не пишется', 'read']].each do |title, key|
      list = groups[key].to_a
      next if list.empty?

      puts
      puts "== #{title}: #{list.size} =="
      list.each do |row|
        marks = []
        marks << "запрос читает в #{row['read_files']} файлах" if row['read_files'].to_i.positive?
        marks << "запрос пишет в #{row['write_files']} файлах" if row['write_files'].to_i.positive?
        marks << "ORM в #{row['orm_files']}" if row['orm_files'].to_i.positive?
        # A link BY NAME: the value is taken by key out of a result hash, and
        # there is no table there. For one such column it is somebody else's
        # query against another table — and the report is obliged to say so, not
        # the reader.
        # A link BY NAME and a link WITH A TABLE are of different strength, and
        # the reader must see the difference: in the first case a column with
        # that name is taken somewhere in the tree, in the second it is visible
        # that the result row was filled by a query against this very table.
        if row['key_table_files'].to_i.positive?
          marks << "значение берут из строк ЭТОЙ таблицы (#{row['key_table_files']} файлов)"
        elsif row['key_files'].to_i.positive?
          marks << "значение берут в #{row['key_files']} файлах (по имени)"
        end
        # Specs only is not a use in the product, but it is not silence either.
        if row['key_files'].to_i.zero? && row['key_test_files'].to_i.positive?
          marks << "названа ТОЛЬКО в спеках (#{row['key_test_files']})"
        end
        marks << "ЧИТАЕТ правило/функция (#{row['db_reads']})" if row['db_reads'].to_i.positive?
        marks << "пишет правило/функция (#{row['db_writes']})" if row['db_writes'].to_i.positive?
        # A field list is a note rather than a proof: it says WHY a column
        # arrives from the database and says nothing about whether the code needs
        # it.
        found = pattern_match.call(row['column_name'])
        marks << "имя собирают узором «#{found['pattern']}» в #{found['files']} файлах" if found
        sibling = sibling_mark.call(row['column_name']) if key == 'none'
        marks << sibling if sibling
        marks << runtime_mark.call(row['column_name']) if %w[none write].include?(key) && runtime_day
        marks << "только названа в списке #{row['list_names']}" if marks.empty? && row['list_names'].present?
        puts format('  %-32s %-24s %s', row['column_name'],
                    row['types'].to_s.split(', ').first.to_s.split(':').last, marks.join(', ')[0, 90])
      end
    end

    unused = groups['none'].to_a.map { |row| row['column_name'] }
    weak_hits = weak_patterns.select { |row| row['usable'] }.filter_map do |row|
      hit = unused.select { |name| name.match?(row['regexp']) }
      [row, hit] if hit.size >= 2
    end
    if weak_hits.any?
      puts
      puts '   ВНИМАНИЕ: имена этих колонок могут собираться в коде, и тогда по слову их не найти.'
      puts '   Узор слабый (буквенная часть короткая), поэтому это не доказательство, а место для глаз:'
      weak_hits.sort_by { |row, hit| -hit.size }.first(6).each do |row, hit|
        puts format('     узор «%s» %-26s совпал с %d: %s', row['pattern'], row['example'],
                    hit.size, hit.first(6).join(', '))
      end
    end

    # A hole in the position of A COLUMN NAME: `"#{make_goal(g)} in (1,2)"`. This
    # is the most honest caveat to the "not used" list: the column name is
    # assembled at runtime, and as a word it does not exist in the tree at all.
    name_holes = conn.select_all(<<~SQL.squish).to_a
      select path, root, expr, array_to_string(lines, ',') as lines from v_sql_holes
      where context = 'column' and path in (
        select distinct path from code_refs
        where kind in ('pg_table', 'pg_table_guess') and token = #{quoted}
      ) order by path limit 6
    SQL
    if name_holes.any?
      puts
      puts "   ВНИМАНИЕ: в запросах этой таблицы #{name_holes.size} мест, где ИМЯ КОЛОНКИ подставляется"
      puts '   выражением — такую колонку по слову не найти, и список выше на эту долю завышен:'
      name_holes.each { |row| puts format('     %s:%s  %s', row['path'], row['lines'].split(',').first, row['expr']) }
    end

    if dynamic.positive?
      puts
      puts format('   (в файлах этой таблицы %d обращений по ключу-ПЕРЕМЕННОЙ у строки-ответа:', dynamic)
      puts format('    %d на строке ЭТОЙ таблицы, у %d таблица неизвестна%s.', dyn['mine'], dyn['unknown'],
                  dyn['others'].to_i.positive? ? ", ещё #{dyn['others']} на строках других таблиц — не в счёт" : '')
      puts '    какую колонку берут там, не видно, и на эту долю список «не используется» завышен.'
      puts '    Счёт НИЖНИЙ: получателя определяем по источнику и имени, и строка-ответ,'
      puts '    названная необычно, в него не попадёт)'
    end

    # The third level of proof: THE LIVE DATA. "The code does not read it" and
    # "there is nothing in the column" are different statements, and the question
    # "what can be dropped" is answered only by the pair. While there was no
    # measurement the answer had to be obtained with a throwaway script, and
    # three times it lied: with `default 1` a column nobody ever touched looks
    # filled for every row.
    fill = conn.select_all(<<~SQL.squish).to_a
      select source, column_name, verdict, filled, off_default, filled_recent, share,
             rows_total, rows_recent, recent_by, measured_at
      from v_column_fill where table_name = #{quoted} order by source, column_name
    SQL
    if fill.empty?
      puts
      puts "== по живым данным: замера нет =="
      puts "   bin/xref fill #{table} — сплошной проход по источнику; без него"
      puts '   «колонку не читают» не отличить от «колонка пустая»'
    else
      by_source = fill.group_by { |row| row['source'] }
      by_source.each do |source, list|
        notable = list.reject { |row| row['verdict'] == 'заполняется' }
        measured = list.first
        puts
        puts format('== по живым данным (%s, %s, строк %s, свежих %s по %s): %d колонок из %d под вопросом ==',
                    source, measured['measured_at'].to_s[0, 10], measured['rows_total'],
                    measured['rows_recent'] || '—', measured['recent_by'] || '—',
                    notable.size, list.size)
        notable.sort_by { |row| [row['verdict'], row['column_name']] }.each do |row|
          code = rows.find { |r| r['column_name'] == row['column_name'] }
          dead = code && mode(code, pattern: pattern_match.call(row['column_name'])) == 'none'
          marks = ["заполнено #{row['filled']} (#{row['share']} %)"]
          marks << "не по умолчанию #{row['off_default']}" if row['off_default']
          marks << "у новых #{row['filled_recent']}" if row['filled_recent']
          marks << 'в коде не используется' if dead
          puts format('  %-30s %-28s %s', row['column_name'], row['verdict'], marks.join(', '))
        end
      end
    end

    # Indexes nobody has read. Not "a redundant field", but the price is the
    # same: disk space and work on every write.
    idx = conn.select_all(<<~SQL.squish).to_a
      select source, index_name, size, since from v_index_unused
      where table_name = #{quoted} and #{Xref::Verdicts.filter_sql('index_unused')}
      order by source, size_bytes desc
    SQL
    if idx.any?
      total = conn.select_value(<<~SQL.squish)
        select pg_size_pretty(sum(size_bytes)) from v_index_unused
        where table_name = #{quoted} and #{Xref::Verdicts.filter_sql('index_unused')}
      SQL
      puts
      puts format('== индексы, которых не читал никто: %d на %s ==', idx.size, total)
      puts format('   счётчики с %s — раньше этой даты сказать нечего', idx.first['since'].to_s[0, 10])
      idx.first(12).each { |row| puts format('  %-34s %-10s %s', row['index_name'], row['size'], row['source']) }
      puts "  … и ещё #{idx.size - 12}" if idx.size > 12
      xref_verdict_note('index_unused')
    end

    # Defects of the field lists themselves. The check is mechanical, the finding
    # is not: a duplicated name takes the place of its neighbour in the series,
    # and a column is filled for 19,452 people while nothing reads it.
    defects = conn.select_all(<<~SQL.squish).to_a
      select kind, list_name, column_name, times, path from v_column_list_defect
      where table_name = #{quoted} and #{Xref::Verdicts.filter_sql('list_defect')}
      order by kind desc, list_name, column_name
    SQL
    if defects.any?
      puts
      puts "== дефекты списков полей этой таблицы: #{defects.size} =="
      defects.each do |row|
        note = row['kind'] == 'повтор в списке' ? "стоит #{row['times']} раза" : "соседей по серии в списке #{row['times']}"
        puts format('  %-18s %-28s %-22s %s  %s', row['kind'], row['list_name'], row['column_name'], note, row['path'])
      end
      xref_verdict_note('list_defect')
    end

    # A column the table lacks in every environment while the code addresses it:
    # such a query cannot run at all.
    cblind = conn.select_all(<<~SQL.squish).to_a
      select column_name, mode, looks_like, path, kind, lines[1] as line from v_column_blind
      where table_name = #{quoted} and #{Xref::Verdicts.filter_sql('column')}
      order by kind, column_name, path
    SQL
    if cblind.any?
      live, aside = cblind.partition { |row| row['kind'] == 'БОЕВОЙ КОД' }
      if live.any?
        puts
        puts "== !! БОЕВОЙ КОД обращается к колонке, которой в таблице НЕТ: #{live.size} =="
        live.each do |row|
          puts format('  %-26s %-8s %s:%s%s', row['column_name'], row['mode'], row['path'], row['line'],
                      row['looks_like'].present? ? "  похоже на: #{row['looks_like']}" : '')
        end
        puts '   такой запрос не исполняется: это не «лишняя колонка», это поломка'
        xref_verdict_note('column')
      end
      # A spec and a script go as a separate class and more quietly: in a spec a
      # query is sometimes DATA (its subject is a failure or the quoting), and
      # nobody executes it.
      if aside.any?
        puts
        puts "   (ещё #{aside.size} в спеках и скриптах: #{aside.map { |r| r['kind'] }.uniq.join(', ')} —"
        puts '    там запрос бывает данными утверждения, а не исполняемым запросом)'
        aside.first(5).each { |row| puts format('      %-24s %s:%s', row['column_name'], row['path'], row['line']) }
      end
    end
    # What was filtered out FOR THIS TABLE goes as a separate line: without it
    # the absence of a section reads as "there are no accesses to non-existent
    # columns here", while the truth may be "there were, they were verified and
    # found false".
    checked_here = conn.select_all(<<~SQL.squish).to_a
      select subject, reason from v_finding_hidden
      where kind = 'column' and subject like '%:' || #{quoted} || '.%' order by subject
    SQL
    if checked_here.any?
      puts
      puts "   (#{checked_here.size} обращений по этой таблице проверены и признаны ложными — в раздел не идут)"
      checked_here.first(5).each { |row| puts format('      %-40s %s', row['subject'].to_s[0, 40], row['reason'].to_s[0, 60]) }
    end

    # A constraint is a consumer too: a column with a foreign key or a check
    # cannot be touched silently, the database will not allow it, and that gets
    # discovered in production.
    holds = conn.select_all(<<~SQL.squish).to_a
      select column_name, kind_name, constraint_name, definition,
             array_to_string(array_agg(distinct source order by source), ',') as sources
      from v_column_constraints
      where table_name = #{quoted} and kind not in ('n', 'p')
      group by 1, 2, 3, 4 order by 1, 2
    SQL
    if holds.any?
      puts
      puts "== колонку держит ограничение: #{holds.size} =="
      holds.first(20).each do |row|
        puts format('  %-24s %-16s %-48s [%s]', row['column_name'], row['kind_name'],
                    row['definition'].to_s[0, 48], row['sources'])
      end
      puts "  … и ещё #{holds.size - 20}" if holds.size > 20
    end

    inbound = conn.select_all(<<~SQL.squish).to_a
      select table_name, constraint_name, definition,
             array_to_string(array_agg(distinct source order by source), ',') as sources
      from v_constraints
      where ref_table = #{quoted} and kind = 'f' group by 1, 2, 3 order by 1
    SQL
    if inbound.any?
      puts
      puts "== на эту таблицу ссылаются внешним ключом: #{inbound.size} =="
      inbound.first(10).each do |r|
        puts format('  %-28s %-58s [%s]', r['table_name'], r['definition'].to_s[0, 58], r['sources'])
      end
    end

    puts
    puts '== чем этот ответ неполон =='
    # The star was the last big ASSUMPTION of this report: "the row may be read
    # by key, and that is not visible". Now it is measured. The star hides
    # exactly one thing — an access where the key is a variable; where there are
    # none, an unread column is unread IN FACT.
    # The caveat about the star is computed with THE SAME number as the caveat
    # above (`dynamic`) rather than with one of its own: two sections of one
    # report computed differently contradict each other — that has already
    # happened here, on the very first run.
    if star.positive?
      puts "  ! к таблице #{star} запросов `select *`: строка приходит целиком"
      if dynamic.zero? && star_cover
        puts format('    но из строк этой таблицы берут по ключу %d имён из %d, и ни одного',
                    star_cover['keys_read'], star_cover['columns'])
        puts '    обращения по ключу-ПЕРЕМЕННОЙ: звезда тут не прячет ничего'
      elsif dynamic.positive?
        puts format('    и %d обращений по ключу-переменной могут брать любую колонку', dynamic)
        puts '    (разбивка выше) — этого индекс не видит'
      else
        puts '    и колонку могут читать по строковому ключу — этого индекс не видит'
      end
    end
    puts "  ! в файлах, трогающих таблицу, #{blind} неразобранных запросов" if blind.positive?
    if runtime_day
      cut = conn.select_one("select count(*) filter (where not parsed)::int as unparsed,
                                    count(*)::int as total from sql_runtime")
      puts format('  ! боевые узоры режутся по 1500 символов, и %d из %d не разобрались:',
                  cut['unparsed'], cut['total'])
      puts '    «в бою не трогали» у колонки из длинного списка полей может быть обрезкой'
    end
    lists = conn.select_value("select count(distinct list_name) from v_column_via_list
                                where column_name in (select column_name from v_column_rw
                                                      where table_name = #{quoted})").to_i
    puts "  ! колонки этой таблицы названы в #{lists} списках полей; у части направление" if lists.positive?
    puts '    (чтение или запись) не прослежено — список собирают в одном месте, а' if lists.positive?
    puts '    подставляют в другом, и этот путь индекс не проходит' if lists.positive?
    xref_zero_note('список мёртвых')
  end

  desc 'Где живёт колонка: bin/xref column NAME=g_marriage'
  task column: :environment do
    xref_fresh!
    name = xref_arg('NAME').presence or abort 'нужен NAME=<имя колонки или его часть>'
    conn = Xref::Store.conn

    rows = conn.select_all(<<~SQL.squish).to_a
      select table_name, column_name, array_to_string(present_in, ',') as present,
             array_to_string(missing_in, ',') as missing,
             array_to_string(types, ' | ') as types,
             array_to_string(types_by_source, ', ') as by_source
      from v_column_presence
      where column_name ilike #{conn.quote("%#{name}%")}
      order by table_name, column_name
    SQL

    if rows.empty?
      puts "колонок по «#{name}» не найдено"
      next
    end

    rows.each do |r|
      line = format('%-46s %-24s [%s]', "#{r['table_name']}.#{r['column_name']}", r['types'], r['present'])
      line += " нет в [#{r['missing']}]" if r['missing'].present?
      puts line
    end
    puts "всего: #{rows.size}"
  end
end
