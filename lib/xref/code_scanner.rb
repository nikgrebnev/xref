# frozen_string_literal: true

require 'prism'
require 'digest'
require 'set'

module Xref
  # Parsing one file: what it touches in the databases.
  #
  # Three sources of information, of differing reliability:
  #
  #   pg_table / pg_column — an SQL string parsed by the database's real parser.
  #                          This is a fact, not a guess.
  #   hb_table / hb_column — literals in columnar-store calls (the first
  #                          argument is the table, the hash keys are
  #                          'family:column').
  #   token                — a name from the database was met in the text of the
  #                          file. This is a CANDIDATE: `status` is found
  #                          everywhere. In exchange it misses nothing.
  #
  # Separately sql_blind / hb_dynamic — places where the name is assembled at
  # runtime (`"select * from #{tbl}"`). The index is obliged to show them as a
  # blind spot rather than stay silent about them.
  class CodeScanner
    # A hole from #{...} in SQL is a query parameter, not the number one.
    #
    # With the number, `"select * from auth_sid#{sid}"` parsed as the table
    # `auth_sid1`: the index silently invented names that do not exist. `$1` is
    # legitimate in a value position, while in a name position it breaks the
    # parse — and the place honestly goes into the blind spots.
    SQL_HOLE = '$1'

    # A marker name for the second parsing attempt: substituted for `#{...}`
    # where a parameter is not legitimate. Checked with grep — it does not occur
    # in the tree.
    IDENT_HOLE = 'xrefhole'

    # `WHERE id = ?` is not a PostgreSQL placeholder, but there is a lot of it
    # in the code. A trailing semicolon is the same kind of surroundings as a
    # space or a parenthesis: `where clip_id = ?;` was skipped by the parse, and
    # the query went into the blind spots entirely because of one character.
    QUESTION_PLACEHOLDER = /(?<=[\s,(=<>])\?(?=[\s,);]|\z)/

    # `create table … as select` and `drop table if exists` are queries too, and
    # the first one reads real columns. While they were not here, a query with
    # thirty columns started with `drop table` and was NOT PARSED AT ALL: all
    # thirty columns were listed as unused while they are read.
    SQL_START = /
      \A\s*(
        select\s | insert\s+into\s | update\s+[a-z_"] | delete\s+from\s | with\s+[a-z_"]
      | create\s+(?:temp\s+|temporary\s+|unlogged\s+)?table\s | drop\s+table\s
      | truncate\s | alter\s+table\s
      )
    /xi

    # A fragment of a query: not a statement but a piece that will be glued
    # together later. `"user_id in (#{sub})"`, `" where #{cond}"`,
    # `"order by #{s}"`.
    #
    # Such places are the most dangerous kind of interpolation and the least
    # noticeable: there is neither `select` nor `from` nearby, and the eye skips
    # over them. There is nothing to parse a fragment with (it is not a
    # statement), but a hole in it is the same hole, and its position in the
    # query reads exactly the same way.
    SQL_FRAGMENT = /
      \A[\s(]*(?:
          (?:and|or|not|where|having|order\s+by|group\s+by|limit|offset|set|values|
             union|from|join|inner\s+join|left\s+join|right\s+join|on)\b
        | (?:\$1|[a-z_][a-z0-9_."]*)\s+(?:not\s+)?(?:in\s*\(|like\b|ilike\b|is\b|between\b)
      )
    /xi
    # There is deliberately no `name = …` branch here. With it, log lines and
    # URL parameters entered the index: `"trace=#{id} n=#{n}"`,
    # `"flm=#{a}&intp=#{b}"`, `"key=#{k}"` — sixteen false findings out of a
    # hundred and seven, all in the "glued to a name" position. Interpolating a
    # value into `a=#{b}` is of little interest anyway.

    # One kind of fragment is not enough: "and #{name} something else" is
    # ordinary text rather than a condition. A sign of real SQL is needed, and a
    # strong one: `from` is deliberately not among them — on it the human phrase
    # "From #{who} on balance" used to enter the index.
    SQL_PART_MARK = /\b(?:select|where|join)\b|\bin\s*\(/i

    # The positions a fragment is parsed for at all. `value`, `quoted`, `limit`
    # and `select_list` are deliberately excluded: those interpolate a value, and
    # the code holds tens of thousands of fragments with values — that would be
    # pure noise.
    FRAGMENT_CONTEXTS = %w[in_list condition table glue order_by group_by set values column].freeze

    # …while these two need no sign of SQL: "order by" does not occur in the
    # middle of ordinary text, and `"order by sort_time #{dir} limit …"` would
    # otherwise be lost.
    FRAGMENT_SELF_EVIDENT = %w[order_by group_by].freeze

    # A columnar-store key of the form 'a:ed' — family and column.
    HB_COLUMN = /\A[a-z][a-z0-9_]*:[a-z0-9_]*\z/i

    MAX_LINES = 20

    Ref = Struct.new(:kind, :token, :owner, :lines, :count, :detail) do
      def key
        [kind, token, owner]
      end
    end

    # Methods whose arguments carry column names directly.
    AR_METHODS = %w[
      where not find_by find_by! order reorder group pluck select
      update_all delete_all exists? find_or_create_by find_or_initialize_by
      first_or_create first_or_initialize sum average minimum maximum
    ].freeze

    attr_reader :path, :source, :known, :model_tables, :app_constants, :column_lists

    def initialize(path, source, known: Set.new, model_tables: {}, app_constants: Set.new,
                   column_lists: {})
      @path = path
      @source = source
      @known = known
      @model_tables = model_tables
      @app_constants = app_constants
      @column_lists = column_lists
      # THE HABITS OF THE TREE from the configuration (Xref.idioms): what gives a
      # result row away, how it is conventionally named, which wrappers take the
      # table as their first argument, which words after `from` are not tables.
      # Baked into the parser they made the tool unportable.
      idioms = Xref.idioms
      @row_source = Regexp.union(Array(idioms[:row_source]).map(&:to_s))
      @row_names = /\A@?(?:#{Array(idioms[:row_names]).map { |n| Regexp.escape(n.to_s) }.join('|')})\z/
      @table_first = Array(idioms[:table_first]).map(&:to_s).to_set
      @guess_stoplist = Array(idioms[:guess_stoplist]).map(&:to_s).to_set
      @prose_is_non_ascii = idioms[:prose_is_non_ascii] != false
      @locale_dirs = %r{\A(?:#{Array(idioms[:locale_dirs]).map { |d| Regexp.escape(d.to_s.chomp('/')) }.join('|')})/}
      # The name of a block parameter -> the columns of the list being looped
      # over.
      @list_params = {}
      @refs = {}
      @rake_task = nil
      @scope_stack = []
      @method = nil
      @sql_here = false
      @visibility = ['public']
      @visibility_named = {}
      @pending_visibility = nil
      @singleton_class = 0
      @assigns = []
      @sql_vars = Set.new
      @wanted_roots = Set.new
      @recorded_holes = Set.new
      @row_vars = Set.new
      # The name of a variable holding a result row -> the lines of the file where
      # the query that filled it stands. That is where a read by key gets its
      # TABLE from.
      @row_origin = {}
      # The name of a variable holding a whole query -> the lines where that
      # query stands. Needed for `sql = "select …"` + `row = select_all(sql)`:
      # the table is named in a line other than the one taking the result row.
      @sql_var_lines = {}
      # The parse of a query by file line: which tables are named and whether
      # there was a star.
      @sql_at_line = {}
      # Reads by key accumulate and are flushed at the end of the walk: a
      # variable may have been filled below the place where it is read.
      @key_reads = []
    end

    # pg_query is loaded on demand and only if it is present.
    #
    # A `require` at the top of the file brought down THE LOADING OF THE
    # APPLICATION wherever the gem is absent: `lib` lies in eager_load_paths,
    # and the production image is built with `BUNDLE_WITHOUT=development:test`.
    # That is, a developer's index would have killed the production server at
    # boot. Without the parser the index is simply poorer: SQL goes into the
    # blind spots and into regexp guesses.
    def self.pg_query?
      return @pg_query unless @pg_query.nil?

      @pg_query = begin
        require 'pg_query'
        true
      rescue LoadError
        false
      end
    end

    def self.language(path)
      case File.extname(path)
      when '.rb', '.rake', '.ru' then 'ruby'
      when '.erb', '.haml', '.slim', '.builder', '.jbuilder' then 'view'
      # TypeScript is parsed by the same parser: the syntax of modules, classes
      # and Stimulus declarations is the same, there are exactly two differences
      # — a method's return type and the access modifiers — and both are handled
      # in Xref::Js.
      when '.js', '.jsx', '.mjs', '.ts', '.tsx', '.mts' then 'js'
      when '.sql' then 'sql'
      when '.md', '.markdown' then 'markdown'
      when '.yml', '.yaml' then 'yaml'
      when '.json' then 'json'
      when '.sh', '.bash' then 'shell'
      when '.conf' then 'conf'
      when '.css', '.scss', '.sass', '.less' then 'css'
      else 'other'
      end
    end

    # => [Ref, ...]
    def scan
      lang = self.class.language(path)
      note_search_blind
      scan_ruby if %w[ruby view].include?(lang) && ruby_parseable?
      # A template is code too: `user['blocked_token']` in an .erb file is the
      # same taking of a value as in .rb. While Prism did not walk the templates,
      # nine thousand accesses by key came from .rb and ZERO from templates — so
      # the answer "nothing takes this column" was about half the tree.
      scan_erb_ruby if lang == 'view' && !ruby_parseable?
      scan_bare_sql if lang == 'sql'
      scan_view if lang == 'view'
      scan_markdown if lang == 'markdown'
      # Stimulus attributes assembled by code occur both in Ruby and in a
      # template: in the former at the helpers, in the latter at
      # `tag.attributes`.
      scan_stimulus_markup(ruby: true) if %w[ruby view].include?(lang)
      scan_structured if %w[yaml json].include?(lang)
      scan_shell if lang == 'shell'
      scan_nginx if lang == 'conf'
      scan_js if lang == 'js'
      scan_css if lang == 'css'
      # Classes from THE MARKUP and from the code are the second half of the
      # question "which styles are not needed": without it there is nothing to
      # compare a declared class against.
      scan_class_usage if %w[view ruby js].include?(lang)
      # Controllers and helpers render views as well.
      scan_renders if lang == 'ruby'
      # After every parse: by this moment it is known which names are
      # interpolated into holes at all, and the assignments are selected by them.
      resolve_table_holes
      flush_assigns
      flush_key_reads
      # The word-candidate layer is NOT built for documents: 157 MB of documents
      # would yield a match for every name from the database in every phrase of
      # the form "in the table below", and the real mentions would drown in them.
      # In a document what counts as named is what is named ON PURPOSE — in
      # backticks or in a code block (see scan_markdown).
      scan_tokens unless %w[markdown yaml json].include?(lang)
      @refs.values
    end

    # The logical name of a view:
    # `app/views/theme_old/searchedit/_sex_with_gal.html.erb` is addressed as
    # `searchedit/sex_with_gal`. That is also where the fact comes from that one
    # edit has to land in several interface modes: their logical name is shared
    # while the files differ.
    def self.view_logical_name(path)
      rest = path.sub(%r{\Aapp/views/}, '')
      dir = File.dirname(rest)
      base = File.basename(rest).sub(/\..*\z/, '').sub(/\A_/, '')
      dir == '.' ? base : "#{dir}/#{base}"
    end

    private

    # A FILE THE TEXT SEARCH CANNOT SEE.
    #
    # A zero byte inside a file makes it BINARY for the search: `git grep` prints
    # "Binary file … matches" instead of the lines (and the output parser throws
    # such a line away), while `rg` with our flags returns NOTHING AT ALL and
    # exits with the code for "nothing found". Measured on a two-file fixture: a
    # name living in the file with a NUL was found by none of the search layers —
    # not by `bin/xref find`, not by the full pass, not by a manual grep — while
    # `ruby -c` and the linter stay silent about such a file. In a second project
    # a live service sat like that (their fix `69720b7`), and it was discovered
    # by eye rather than by a search.
    #
    # The parse does read the file: NUL is legitimate UTF-8, and neither `scrub`
    # nor reading removes it. So the index KNOWS about such a file and is obliged
    # to say so out loud — otherwise "this is not in the tree" is a lie with
    # nothing to catch it.
    def note_search_blind
      return unless source.include?("\u0000")

      add('search_blind', 'NUL-байт: текстовый поиск этот файл не видит', '', 1)
    end

    def ruby_parseable?
      File.extname(path) == '.rb' || File.extname(path) == '.rake' || File.extname(path) == '.ru'
    end

    def add(kind, token, owner, line, detail: nil)
      token = token.to_s
      return if token.empty?

      ref = (@refs[[kind, token, owner.to_s]] ||= Ref.new(kind, token, owner.to_s, [], 0, detail))
      ref.count += 1
      ref.lines << line if ref.lines.size < MAX_LINES
      merge_expr(ref, detail) if detail && ref.detail && !ref.detail.equal?(detail)
    end

    # One name, one place — but different expressions: `#{ids.join(',')}` and
    # `#{ids.map(&:to_i).join(',')}`, `sql << ' where …'` and
    # `sql << ' order by …'`. A shared key, a different meaning. The first lies
    # in expr/value, the rest (up to four) alongside, otherwise the record would
    # show only the very first line.
    def merge_expr(ref, detail)
      text = detail[:expr] || detail[:value]
      collect(ref.detail, :more, text) unless ref.detail[:expr] == text || ref.detail[:value] == text
      # The same hole in three methods of one file — one row, but the methods
      # differ, and the `scope` of the first of them lies about the others.
      collect(ref.detail, :scopes, detail[:scope]) unless ref.detail[:scope] == detail[:scope]
    end

    def collect(store, key, text)
      return if text.blank?

      list = (store[key] ||= [])
      list << text if list.size < 4 && !list.include?(text)
    end

    # --- ruby ---------------------------------------------------------------

    # ERB is assembled into Ruby with the line numbers preserved: the pieces
    # outside the tags are replaced with newlines, so the line of a discovered
    # access matches the line of the template. After that it is the same walk as
    # for `.rb`: there must be no separate parsing branch, otherwise templates
    # and code drift apart silently.
    def scan_erb_ruby
      ruby = Erb.ruby(source)
      walk_ruby(ruby) unless ruby.strip.empty?
    end

    def scan_ruby
      walk_ruby(source)
    end

    # One walk for both entrances — and one failure handler. Without the
    # `rescue` here an exception from parsing ONE file brought down the entire
    # `xref:code` run.
    def walk_ruby(text)
      result = Prism.parse(text)
      return unless result.success?

      # The names of environment keys often live in CONSTANTS:
      # `LEASE_SECONDS_ENV = "SETTINGS_MEDIA_PROCESSING_LEASE_SECONDS"`, read as
      # `ENV[LEASE_SECONDS_ENV]`. Without this map the parse ran into a
      # `ConstantReadNode` and the key did not reach the index AT ALL: the report
      # `bin/xref env` called 30-plus settings "read by nobody", including the
      # ones that are read (a second project, 2026-10-09). It lied in both
      # directions at once: a key missing from the environment would not have
      # been found either.
      @string_constants = collect_string_constants(result.value)

      # Pieces of an interpolated string are not strings of their own. Without
      # this the stump `insert into t (a, b) values (` would go into the blind
      # spots while the whole string was parsed right next to it.
      @inner = Set.new
      @rake_ns = []
      walk(result.value)
      # `private :old_method` stands below the declaration — visibility is fixed
      # up after the walk, otherwise such methods would be listed as public.
      @visibility_named.each do |(owner, method), level|
        ref = @refs[['def', method, owner]]
        ref.detail[:visibility] = level if ref&.detail
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    # A walk with two peculiarities.
    #
    # For `namespace`/`task` in rake files we remember whose task body we are
    # inside. Otherwise every robot from robots.rake would merge into one node,
    # and "where is this file reachable from" would lose its meaning.
    #
    # For `class`/`module`/`def` we remember whose body we are inside. Without
    # that the finding "a query was assigned to the variable sql" would point at
    # a file, while a file holds a dozen such variables — all with the same name.
    def walk(node)
      return if node.nil?

      handle_node(node)
      bound = bind_list_params(node)
      rows = bind_row_params(node)

      case node
      when Prism::ClassNode, Prism::ModuleNode
        @scope_stack.push(constant_name(node.constant_path))
        @visibility.push('public')
        node.compact_child_nodes.each { |child| walk(child) }
        @visibility.pop
        @scope_stack.pop
        return
      when Prism::SingletonClassNode
        # `class << self` — the methods inside are class methods, and `private`
        # there is its own.
        @visibility.push('public')
        @singleton_class += 1
        node.compact_child_nodes.each { |child| walk(child) }
        @singleton_class -= 1
        @visibility.pop
        return
      when Prism::DefNode
        previous_method = @method
        previous_sql = @sql_here
        singleton = !node.receiver.nil? || @singleton_class.positive?
        @method = "#{singleton ? '.' : '#'}#{node.name}"
        @sql_here = false
        node.compact_child_nodes.each { |child| walk(child) }
        returns = sql_return_kind(node)
        add('def', node.name.to_s, @scope_stack.join('::'), node.location.start_line,
            detail: { sql: @sql_here, returns: returns == 'whole', returns_part: returns == 'part',
                      params: parameter_names(node), singleton: singleton,
                      # The length of the method in lines. Written HERE, because
                      # here it is already known. The "dead methods" report used
                      # to compute it afterwards — re-reading and re-parsing with
                      # Prism every file with a finding — and `bin/xref dead`
                      # answered in 48 s, of which 40 went exactly on that. Two
                      # hundred one-line wrappers and two hundred hundred-line
                      # routines are a different conversation, so the number is
                      # needed; but there is no reason to take it twice.
                      size: node.location.end_line - node.location.start_line + 1,
                      visibility: @pending_visibility || @visibility.last })
        @pending_visibility = nil
        @method = previous_method
        @sql_here = previous_sql
        return
      end

      if node.is_a?(Prism::CallNode) && node.block
        label = rake_label(node)
        case node.name.to_s
        when 'namespace'
          if label
            @rake_ns.push(label)
            node.compact_child_nodes.each { |child| walk(child) }
            @rake_ns.pop
            return
          end
        when 'task'
          if label
            previous = @rake_task
            @rake_task = (@rake_ns + [label]).join(':')
            add('rake_entry', @rake_task, '', node.location.start_line)
            node.compact_child_nodes.each { |child| walk(child) }
            @rake_task = previous
            return
          end
        end
      end

      node.compact_child_nodes.each { |child| walk(child) }
      bound.each { |name| @list_params.delete(name) }
      # The PREVIOUS value is restored rather than deleted: a `row` outside the
      # loop could mean another table, and deleting would silently erase it.
      rows.each { |name, previous| previous.nil? ? @row_origin.delete(name) : @row_origin[name] = previous }
    end

    # A loop over a field list: `fields_for_legacy.each { |par| member_info[par] }`
    # reads exactly the columns in the list. The block parameter is bound to the
    # composition — and an access by variable stops being a blind spot.
    #
    # The composition comes either from a previous parse (the `column_lists`
    # input) or from this very file, if the list is declared here. The binding is
    # dropped at the end of the node walk: outside the block the parameter means
    # nothing.
    ITERATORS = %w[each each_with_index map flat_map each_with_object select filter
                   reject find detect sum count sort_by group_by partition].freeze
    def bind_list_params(node)
      return [] unless node.is_a?(Prism::CallNode) && node.block
      return [] unless ITERATORS.include?(node.name.to_s)

      columns = list_columns_of(node.receiver)
      return [] if columns.blank?

      names = block_parameter_names(node.block)
      names.each { |name| @list_params[name] = columns }
      names
    end

    # A loop over result rows: `res.each do |line| … line['contact'] … end`.
    # This is the most common form of a column read in this tree, and without
    # binding the parameter to its source the read's table stayed unknown:
    # `key_read` knew the column name and did not know whose table it was. And
    # the question is always asked about a table.
    def bind_row_params(node)
      return [] unless node.is_a?(Prism::CallNode) && node.block
      return [] unless ITERATORS.include?(node.name.to_s)

      origin = row_origin_for(node.receiver)
      return [] if origin.blank?

      block_parameter_names(node.block).to_h do |name|
        previous = @row_origin[name]
        @row_origin[name] = origin
        [name, previous]
      end
    end

    # Where the query that produced this result row lives. Either at a variable
    # (it was filled above) or right in the receiver:
    # `select_all(…).to_a.each do |row|`.
    def row_origin_for(receiver)
      case receiver
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        @row_origin[receiver.name.to_s]
      when Prism::CallNode
        name = root_variable_name(receiver)
        return @row_origin[name] if name && @row_origin.key?(name)
        return nil unless receiver.slice.to_s.match?(@row_source)

        (receiver.location.start_line..receiver.location.end_line).to_a
      end
    end

    # The root of a call chain as a NAME. `row['x']` where `row` is assigned
    # from nowhere is read by Prism as a call with no receiver and no arguments —
    # and that is the very common case the name is needed for here.
    def root_variable_name(node)
      current = node
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver

      case current
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then current.name.to_s
      when Prism::CallNode then current.arguments.nil? && current.block.nil? ? current.name.to_s : nil
      end
    end

    def list_columns_of(receiver)
      # Most often the list stands RIGHT IN THE LOOP:
      # `['show_in_catalogue','sort_priority','sex'].each { |par| info[par] }`.
      # Such a list has no name, and binding by name did not find it — while
      # this is the most common form of a loop over columns in this tree.
      inline = inline_column_list(receiver)
      return inline if inline

      current = receiver
      # `FIELDS.split(',')`, `list.dup`, `fields.keys` — the tail of calls is
      # stripped.
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      name = case current
             when Prism::ConstantReadNode then current.name.to_s
             when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then current.name.to_s
             when Prism::CallNode then current.name.to_s
             end
      return nil if name.blank?

      local = @refs[['col_list', name, scope_name]] || @refs.values.find do |ref|
        ref.kind == 'col_list' && ref.token == name
      end
      local&.detail&.dig(:columns) || column_lists[name]
    end

    # An array of literals in the receiver: taken only if EVERY element is a
    # known column name. Otherwise any loop over words lands here.
    def inline_column_list(receiver)
      current = receiver
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      return nil unless current.is_a?(Prism::ArrayNode)

      items = current.elements.map do |element|
        case element
        when Prism::StringNode then element.unescaped
        when Prism::SymbolNode then element.value.to_s
        end
      end
      return nil if items.size < 2 || items.any?(&:nil?)
      return nil unless items.all? { |item| known.include?(item) }

      items
    end

    def block_parameter_names(block)
      parameters = block.respond_to?(:parameters) ? block.parameters : nil
      parameters = parameters.parameters if parameters.respond_to?(:parameters)
      return [] if parameters.nil?

      Array(parameters.requireds).filter_map do |param|
        param.name.to_s if param.respond_to?(:name)
      end
    end

    def handle_node(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then handle_constant(node)
      when Prism::CallNode then handle_call(node)
      when Prism::InterpolatedStringNode
        # A nested piece of a concatenation is parsed together with the whole;
        # parsing it separately is not allowed: the stump would go into the blind
        # spots next to the whole.
        return if @inner.include?(node.object_id)

        mark_inner(node)
        text, _interpolated, merged, holes = literal(node)
        if text&.match?(SQL_START)
          analyze_sql(text, node.location.start_line, blind: merged, holes: holes)
        elsif holes.present? && text.match?(SQL_FRAGMENT)
          record_holes(text, holes, node.location.start_line, blind: merged, fragment: true)
        end
        note_name_pattern(text, holes, node.location.start_line)
        note_sql_expression(text, node.location.start_line) unless text&.match?(SQL_START)
      when Prism::StringNode
        return if @inner.include?(node.object_id)

        text, = literal(node)
        if text.match?(SQL_START)
          analyze_sql(text, node.location.start_line)
        else
          note_sql_expression(text, node.location.start_line)
        end
      when Prism::OrNode then note_env_fallback(node)
      when Prism::IfNode, Prism::UnlessNode then note_env_flag(node)
      when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode,
           Prism::ClassVariableWriteNode, Prism::GlobalVariableWriteNode,
           Prism::ConstantWriteNode
        note_assign(node.name.to_s, node.value, node.location.start_line, '=')
      when Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
           Prism::ClassVariableOperatorWriteNode, Prism::GlobalVariableOperatorWriteNode
        note_assign(node.name.to_s, node.value, node.location.start_line, "#{node.binary_operator}=")
      end
    end

    # Pieces of a query assembled WITHOUT interpolation and not starting with a
    # keyword: `"paid_until-paid_from<'32 days'::interval"`,
    # `'pay_method<>6'`. They counted neither as a whole query nor as a
    # fragment with a hole, and a column named only that way was listed as
    # unused. That is exactly where the owner caught the report:
    # `paid_from` is read by two cron jobs.
    #
    # THE PARSER decides, not a regexp: `select <piece>` either parses or it does
    # not. Three conditions suffice for the filtering — there is a known name,
    # there is an operator sign, the string is short. Otherwise CSS, date formats
    # and human text crawl in here.
    SQL_EXPR_MARK = %r{[<>=+*/(,]|-\w|::|\b(?:interval|coalesce|and|or|not\s+null)\b}i
    SQL_EXPR_MAX = 300

    # Parsing the same string repeats: `'pay_method<>6'` occurs dozens of
    # times in the tree. The memo of parse attempts lives for the whole run, and
    # it is cheaper than the parse itself: after this kind was added a full pass
    # grew from 95 to 144 seconds, and half the time went on repeats.
    # The memo lives for the whole process but is keyed BY THE SET OF KNOWN
    # NAMES: with another set the same text gives another answer, and a shared
    # memo would silently return somebody else's. Within an `xref:code` run the
    # set is one, while in the specs they differ.
    @expression_cache = {}
    @expression_known = nil
    class << self
      def expression_cache(known)
        if @expression_known != known.object_id
          @expression_cache = {}
          @expression_known = known.object_id
        end
        @expression_cache
      end
    end

    def note_sql_expression(text, line)
      return if text.blank? || text.length > SQL_EXPR_MAX || !self.class.pg_query?
      return unless text.match?(SQL_EXPR_MARK)

      words = text.scan(/[a-z_][a-z0-9_]*/i)
      return if words.none? { |word| known.include?(word) }

      cache = self.class.expression_cache(known)
      cached = cache[text]
      if cached
        cached.each { |column| add('pg_column_expr', column, '', line) }
        return
      end

      parsed = PgQuery.parse("select #{text.gsub(QUESTION_PLACEHOLDER, SQL_HOLE)}")
      # The expression must contain AN OPERATOR. Without this check the field
      # list itself (`'user_id,username,member_partner,…'`) parses as
      # `select a,b,c` and declares every column of the list used — that is,
      # precisely the error for which a list stopped counting as proof.
      unless operation?(parsed)
        cache[text] = []
        return
      end

      found = column_refs(parsed).filter_map { |_qualifier, column| column if known.include?(column) }
      cache[text] = found
      # There is no owner here and there cannot be: the piece holds no `from`.
      # The link is by name, the same as for taking a value by key, and the
      # report says so.
      found.each { |column| add('pg_column_expr', column, '', line) }
    rescue StandardError
      self.class.expression_cache(known)[text] = []
      nil
    end

    # Node names rather than constants: the `PgQuery::*` constants must not be
    # touched while the file loads — the gem sits in the `development` group and
    # is loaded on demand.
    OPERATION_NODES = %w[A_Expr FuncCall TypeCast BoolExpr NullTest CaseExpr].freeze

    def operation?(parsed)
      found = false
      parsed.walk! do |*nodes|
        nodes.flatten.each do |node|
          found = true if OPERATION_NODES.include?(node.class.name.to_s.split('::').last)
        end
      end
      found
    rescue StandardError
      false
    end

    # A NAME-string assembled by interpolation: `"g#{ar.join('_')}"` yields the
    # pattern `g$1`, `"language#{num}_2"` yields `language$1_2`. Such a string is
    # almost always a column or key name, and for the question "which fields we
    # do not use in the code" that is decisive evidence: searching the tree for
    # the word `opt3_4` finds nothing, because it is not there — it is assembled.
    #
    # A pattern does not prove that EXACTLY this column is taken, so in the
    # report it goes into a separate section rather than into "is read". The
    # filter: identifier characters only, no spaces — otherwise every
    # interpolated string crawls in here.
    NAME_PATTERN = /\A[A-Za-z0-9_$]+\z/
    def note_name_pattern(text, holes, line)
      return if text.blank? || holes.blank? || !text.match?(NAME_PATTERN)
      return if text.delete(SQL_HOLE).empty?

      add('name_pattern', text, '', line, detail: { expr: hole_list(holes), scope: scope_name })
    end

    # Pieces of a concatenation are not strings of their own, and the nesting
    # goes deeper than one level: `"a" \ "b#{x}" \ "c"` inside yet another such
    # concatenation.
    def mark_inner(node)
      node.parts.each do |part|
        @inner << part.object_id
        mark_inner(part) if part.is_a?(Prism::InterpolatedStringNode)
      end
    end

    # `task :bounces do`, `task bounces: :environment do`, `task 'x' => [...]`.
    def rake_label(node)
      argument = node.arguments&.arguments&.first
      case argument
      when Prism::SymbolNode then argument.unescaped.scrub('')
      when Prism::StringNode then argument.unescaped.scrub('')
      when Prism::HashNode, Prism::KeywordHashNode
        key = argument.elements.grep(Prism::AssocNode).first&.key
        literal(key)&.first
      end
    end

    # A reference to a constant of the application is an edge of the "file ->
    # file" graph. Foreign and standard constants are not taken: the path map
    # does not know them anyway.
    def handle_constant(node)
      name =
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then (node.full_name rescue nil).to_s
        end
      return if name.blank? || !app_constants.include?(name)

      add('const_ref', name, @rake_task.to_s, node.location.start_line)
    end

    VISIBILITY = %w[private protected public].freeze

    # `private` changes the visibility of everything declared below it in this
    # body; in the three other forms — `private def x`, `private :x, :y`,
    # `private_class_method :x` — it names the methods explicitly. Visibility is
    # needed for one question: for a private method "no calls by name" means
    # "dead", while for a public one it only means "not called within this tree".
    def handle_visibility(node)
      name = node.name.to_s
      return unless VISIBILITY.include?(name) || name == 'private_class_method'
      return unless node.receiver.nil?

      level = name == 'private_class_method' ? 'private' : name
      arguments = node.arguments&.arguments || []
      if arguments.empty?
        @visibility[-1] = level if VISIBILITY.include?(name)
        return
      end

      @pending_visibility = level if arguments.any? { |a| a.is_a?(Prism::DefNode) }
      arguments.each do |argument|
        next unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

        @visibility_named[[@scope_stack.join('::'), argument.unescaped.to_s]] = level
      end
    end

    def handle_call(node)
      handle_visibility(node)
      note_append(node) if node.name == :<<
      handle_key_read(node)
      handle_env_key(node)
      handle_i18n(node)
      handle_ar_call(node) if AR_METHODS.include?(node.name.to_s)
      return unless hbase_call?(node)

      args = node.arguments&.arguments || []
      line = node.location.start_line

      text, interpolated, _merged, holes = literal(args.first)
      if text && !interpolated
        add('hb_table', text, '', line)
      else
        # A columnar-store table name assembled at runtime. The index cannot say
        # which table that is — but it is obliged to say WHAT it is assembled
        # from: without that the record "hb_execute, a blind spot" does not even
        # give a place to start.
        expression = hole_list(holes)
        expression = args.first&.slice.to_s[0, 120].to_s.gsub(/\s+/, ' ').strip if expression.empty?
        add('hb_dynamic', node.name.to_s, '', line,
            detail: { expr: expression, skeleton: text&.gsub(SQL_HOLE, '*'), scope: scope_name })
        Array(holes).each { |hole| @wanted_roots << hole_root(hole[:expr]) }
      end

      # The owner of a column is only a name assembled in full. For
      # `"s_forum#{id}_approve"` the owner used to be recorded as the string with
      # the hole, `s_forum$1_approve` — that is, a table that does not exist.
      table = interpolated ? '' : text.to_s

      args.grep(Prism::HashNode).each do |hash|
        hash.elements.grep(Prism::AssocNode).each do |assoc|
          key, key_interpolated, _key_merged, key_holes = literal(assoc.key)
          if key_interpolated && key.to_s.include?(':')
            add('hb_dynamic', "колонка #{key}", table, line, detail: { expr: hole_list(key_holes) })
            next
          end
          next if key.nil? || !key.match?(HB_COLUMN)

          add('hb_column', key, table, line)
        end
      end

      # atomic_incr_when_error(table, column, …) — the column comes as a bare
      # argument.
      args.drop(1).each do |arg|
        value, arg_interpolated, _arg_merged, arg_holes = literal(arg)
        next if value.nil? || !value.include?(':')

        if arg_interpolated
          add('hb_dynamic', "колонка #{value}", table, line, detail: { expr: hole_list(arg_holes) })
        elsif value.match?(HB_COLUMN)
          add('hb_column', value, table, line)
        end
      end
    end

    # What gives away a variable holding a result row. Either its source (it was
    # assigned the result of a query) or its name: `row`, `line`, `info` have
    # meant the same thing in this tree for thirty years.

    # The methods that take a value out of a result row: `row['member_messenger']`,
    # `info.fetch(:sex)`, `row.dig('meta')`. `[]=` is NOT among them: that is a
    # write into one's own hash rather than a column read.
    KEY_METHODS = %i[[] fetch dig].freeze

    # `I18n.t('login.invalid')`, `t('.title')` — a translation key. Recorded in
    # order to compare against the store: no key means a human sees either
    # English (fallbacks hide the gap) or "translation missing".
    #
    # A relative key (`t('.title')`) is resolved BY PLACE: in a template by its
    # path, in a controller by the class and the action. Without that half the
    # keys would stay unfindable: a leading dot means nothing on its own.
    I18N_METHODS = %i[t translate t! translate!].freeze
    def handle_i18n(node)
      return unless I18N_METHODS.include?(node.name)

      receiver = node.receiver
      return unless receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :I18n)

      arguments = node.arguments&.arguments || []
      argument = arguments.first
      line = node.location.start_line
      # `scope:` and `default:` are BOTH read, and each of them otherwise yields
      # a false finding. `I18n.t :send, scope: 'general'` is the key
      # `general.send`, and it exists in the store in eighteen languages;
      # `t('general.refresh', default: 'Refresh')` will never show a human
      # "translation missing". Of 22 "missing translations" three turned out to
      # be those.
      scope_prefix, has_default = i18n_options(arguments)
      case argument
      when Prism::StringNode, Prism::SymbolNode
        raw = argument.respond_to?(:unescaped) ? argument.unescaped : argument.value.to_s
        return if raw.empty? || !raw.match?(/\A\.?[a-z0-9_.]+\z/i)

        key = if raw.start_with?('.')
                "#{i18n_scope}#{raw}"
              elsif scope_prefix
                "#{scope_prefix}.#{raw}"
              else
                raw
              end
        detail = { relative: raw.start_with?('.') }
        detail[:scoped] = true if scope_prefix
        detail[:default] = true if has_default
        add('i18n_key', key, scope_name, line, detail: detail)
      when Prism::InterpolatedStringNode
        text, _interpolated, _merged, holes = literal(argument)
        add('i18n_dynamic', text.to_s[0, 80], scope_name, line,
            detail: { expr: hole_list(holes) })
      end
    end

    # `scope:` comes as a string, as a symbol and as an ARRAY
    # (`scope: [:mail, :form]`), while `default:` comes as anything at all; all
    # that matters to us is that it is there.
    def i18n_options(arguments)
      hash = arguments.drop(1).grep(Prism::KeywordHashNode).first ||
             arguments.drop(1).grep(Prism::HashNode).first
      return [nil, false] if hash.nil?

      prefix = nil
      has_default = false
      hash.elements.grep(Prism::AssocNode).each do |assoc|
        name, = literal(assoc.key)
        case name
        when 'scope' then prefix = i18n_scope_value(assoc.value)
        when 'default' then has_default = true
        end
      end
      [prefix, has_default]
    end

    def i18n_scope_value(value)
      case value
      when Prism::StringNode, Prism::SymbolNode
        text = value.respond_to?(:unescaped) ? value.unescaped : value.value.to_s
        text.presence
      when Prism::ArrayNode
        parts = value.elements.filter_map do |item|
          if item.respond_to?(:unescaped) then item.unescaped
          elsif item.respond_to?(:value) then item.value.to_s
          end
        end
        parts.join('.').presence
      end
    end

    # The namespace a dotted key is resolved against. For a template it is its
    # path (`app/views/users/_form.erb` → `users.form`), for a controller the
    # class and the action (`UsersController#show` → `users.show`).
    def i18n_scope
      if path.start_with?('app/views/')
        self.class.view_logical_name(path).tr('/', '.')
      elsif @method && scope_name.to_s.include?('Controller#')
        klass, method = scope_name.split('#', 2)
        "#{klass.sub(/Controller\z/, '').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase}.#{method}"
      else
        ''
      end
    end

    # `ENV['KEY']`, `ENV.fetch('KEY')`, `ENV.key?('KEY')` — the name of an
    # environment key. ONLY the name is written: there is no value in the index
    # and there cannot be, they are never read at all. Needed in order to compare
    # against what the environment defines: a key the node does not have returns
    # nil silently.
    ENV_METHODS = %i[[] fetch key? has_key? include?].freeze
    # Constants of the file assigned a string LITERAL. The simple form only,
    # `CONST = "string"`: interpolation and concatenation are deliberately not
    # parsed — they produce a name that does not exist in the source in full, and
    # that is a separate class (`bin/xref holes`).
    def collect_string_constants(root)
      map = {}
      stack = [root]
      until stack.empty?
        node = stack.pop
        next unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::ConstantWriteNode) && (value = constant_string(node.value))
          map[node.name.to_s] = value
        end
        node.compact_child_nodes.each { |child| stack.push(child) }
      end
      map
    end

    # The value of a constant, if it is a string literal — including through
    # `.freeze`/`.dup`. Without the tail not a single constant of this tree would
    # have qualified: here people write
    # `KEY = 'SOCIAL_PHOTO_IMPORT_ENABLED'.freeze`, and that is already a call
    # rather than a literal (measured: 12 such constants, of which zero match the
    # rule without the tail).
    STRING_TAIL = %i[freeze dup to_s].freeze

    def constant_string(value)
      return value.unescaped if value.is_a?(Prism::StringNode)
      return nil unless value.is_a?(Prism::CallNode) && STRING_TAIL.include?(value.name)

      constant_string(value.receiver)
    end

    def handle_env_key(node)
      return unless ENV_METHODS.include?(node.name)

      receiver = node.receiver
      return unless receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :ENV

      argument = node.arguments&.arguments&.first
      name =
        case argument
        when Prism::StringNode then argument.unescaped
        when Prism::SymbolNode then argument.value.to_s
        when Prism::ConstantReadNode then (@string_constants || {})[argument.name.to_s]
        end
      return if name.nil? || name.empty?

      add('env_key', name, scope_name, node.location.start_line)
      # `ENV.fetch('X', 'default')` — the key may legitimately be absent.
      # Without this class the report "the key is missing from the environment"
      # throws a real hole and an ordinary setting with a fallback into one pile.
      add('env_default', name, scope_name, node.location.start_line) if node.name == :fetch &&
                                                                        (node.arguments&.arguments&.size.to_i > 1 ||
                                                                         node.block)
    end

    # `if ENV['X']`, `unless ENV['X'].to_i.zero?` — the key is read as a FLAG:
    # an empty value is legitimate here and means "switched off". Without this
    # class the report "the key is defined in no environment" comes out a hundred
    # and thirty-eight lines long, and the real holes cannot be found in it.
    def note_env_flag(node)
      found = env_key_in(node.predicate)
      add('env_flag', found, scope_name, node.location.start_line) if found
    end

    # The key name inside a condition expression: `ENV['X']`,
    # `ENV['X'].to_i > 1`, `ENV['X'].present?`, `ENV.fetch('X', nil)`.
    def env_key_in(node)
      return nil if node.nil?

      current = node
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      return nil unless current.is_a?(Prism::ConstantReadNode) && current.name == :ENV

      call = node
      call = call.receiver while call.is_a?(Prism::CallNode) && !ENV_METHODS.include?(call.name)
      return nil unless call.is_a?(Prism::CallNode)

      argument = call.arguments&.arguments&.first
      return nil unless argument.is_a?(Prism::StringNode) || argument.is_a?(Prism::SymbolNode)

      name = argument.respond_to?(:unescaped) ? argument.unescaped : argument.value.to_s
      name.presence
    end

    # `ENV['X'] || 'default'`, `ENV['X'].presence || …` — the same thing written
    # differently. The parent is visible only here: the walk goes top-down.
    def note_env_fallback(node)
      left = node.left
      left = left.receiver while left.is_a?(Prism::CallNode) && left.receiver.is_a?(Prism::CallNode)
      return unless left.is_a?(Prism::CallNode) && ENV_METHODS.include?(left.name)
      return unless left.receiver.is_a?(Prism::ConstantReadNode) && left.receiver.name == :ENV

      argument = left.arguments&.arguments&.first
      return unless argument.is_a?(Prism::StringNode) || argument.is_a?(Prism::SymbolNode)

      name = argument.respond_to?(:unescaped) ? argument.unescaped : argument.value.to_s
      add('env_default', name, scope_name, node.location.start_line) unless name.empty?
    end

    # THE MOST IMPORTANT kind of column access, and the index did not have it.
    #
    # When a query selects the whole field list (`select #{FIELDS} from …`) or
    # selects with a star, "the column is named in the code" means nothing: it is
    # named once, in the list, and that is not a use. A use is when the VALUE is
    # taken by key. Without this kind the report answered the question "which
    # fields we do not use" with "the direction was not traced" and hid the
    # answer: nothing takes `member_photo` and `member_photo_type`, while `member_messenger`
    # is taken — in one place.
    #
    # A variable key (`row[field]` in a loop over a list) is invisible here, and
    # that is counted separately: in the report such accesses are named by a
    # number rather than forgotten.
    def handle_key_read(node)
      return unless KEY_METHODS.include?(node.name)

      argument = node.arguments&.arguments&.first
      return if argument.nil?

      receiver = node.receiver

      case argument
      when Prism::StringNode, Prism::SymbolNode
        name = argument.respond_to?(:unescaped) ? argument.unescaped : argument.value.to_s
        return unless known.include?(name)

        note_key_read('key_read', name, node, receiver)
      when Prism::InterpolatedStringNode
        # The key is assembled by interpolation — but the PATTERN is known:
        # `info["language#{num}_2"]` yields `language$1_2`. That is not a blind
        # spot but precisely a pattern, and the columns of a series are
        # recognisable through it. Without this kind eight `language*_2`/
        # `lang*_mark` columns ended up in my "not used" while they are read in
        # three places.
        text, _interpolated, _merged, holes = literal(argument)
        return if text.nil? || !text.include?(SQL_HOLE) || text.delete(SQL_HOLE).length < 3

        note_key_read('key_pattern', text, node, receiver, extra: { expr: hole_list(holes) })
      when Prism::LocalVariableReadNode, Prism::CallNode, Prism::InstanceVariableReadNode
        # The key is a whole variable: which column that is stays unknown. But
        # recording it as a blind spot OVER COLUMNS is allowed only where the
        # receiver really is a result row. `Dir[glob]`, `ids[i]`,
        # `@countries[code]` are ordinary accesses to an array or a hash, and
        # they have no place in a count of ignorance about columns: of 7,906
        # accesses more than six thousand turned out to be those.
        # A parameter of a loop over a field list: the columns are known — so
        # this is a read rather than a blind spot.
        bound = argument.is_a?(Prism::LocalVariableReadNode) && @list_params[argument.name.to_s]
        if bound
          bound.each do |column|
            note_key_read('key_read', column, node, receiver, extra: { via: "цикл по #{argument.name}" })
          end
          return
        end

        return unless row_like?(receiver)

        note_key_read('key_dynamic', node.name.to_s, node, receiver,
                      extra: { expr: argument.slice.to_s[0, 60], on: receiver&.slice.to_s[0, 40] })
      end
    end

    # The read is deferred: the table will be named by a query, and the query may
    # stand below — in another method of the same file, or in an `.each` over a
    # variable not yet walked. It is written to the index after the walk, once the
    # parse of the file's queries is finished.
    def note_key_read(kind, token, node, receiver, extra: {})
      @key_reads << { kind: kind, token: token, line: node.location.start_line,
                      origin: receiver_origin(receiver), scope: scope_name }.merge(extra)
    end

    def receiver_origin(receiver)
      case receiver
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        @row_origin[receiver.name.to_s]
      when Prism::CallNode
        name = root_variable_name(receiver)
        name && @row_origin[name]
      end
    end

    # The owner is written ONLY when the query named a single table. In a join of
    # two tables attributing the column to either of them means inventing it —
    # and this record later answers the question "which fields of the table we do
    # not use", so an invented owner makes the answer false in the dangerous
    # direction.
    def flush_key_reads
      @key_reads.each do |read|
        detail = read.slice(:scope, :expr, :on, :via).compact
        add(read[:kind], read[:token], owner_of_origin(read[:origin]).to_s, read[:line], detail: detail)
      end
      @key_reads.clear
    end

    def owner_of_origin(origin)
      return nil if origin.blank?

      tables = origin.flat_map { |line| @sql_at_line.dig(line, :tables) || [] }.uniq
      tables.size == 1 ? tables.first : nil
    end

    def row_like?(receiver)
      case receiver
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        name = receiver.name.to_s
        @row_vars.include?(name) || @row_vars.include?(name.delete('@')) || name.match?(@row_names)
      when Prism::CallNode
        # Two cases. A chain with the query itself (`select_all(…).to_a[i]`) —
        # that qualifies. And a bare name: `row[field]` where `row` is assigned
        # from nowhere is read by Prism as a CALL rather than a variable — and
        # that is the very common case.
        (receiver.receiver.nil? && receiver.arguments.nil? && receiver.name.to_s.match?(@row_names)) ||
          receiver.slice.to_s.match?(@row_source)
      else
        false
      end
    end

    # `BigUser.where(g1: 1).order(:opt2_1)` — the columns are visible right in the
    # arguments, yet they appear in no SQL string. The owner is looked for by the
    # root of the call chain: the receiver of `.order` is the `.where` itself, and
    # so on up to the model constant.
    def handle_ar_call(node)
      args = node.arguments&.arguments || []
      return if args.empty?

      owner = model_tables[receiver_root(node)].to_s
      line = node.location.start_line

      args.each do |arg|
        case arg
        when Prism::SymbolNode
          add_ar_column(arg.unescaped.scrub(''), owner, line)
        when Prism::HashNode, Prism::KeywordHashNode
          arg.elements.grep(Prism::AssocNode).each do |assoc|
            name, interpolated = literal(assoc.key)
            add_ar_column(name, owner, line) if name && !interpolated
          end
        end
      end
    end

    # Known names only: otherwise every key of every hash in the code lands here.
    def add_ar_column(name, owner, line)
      return if name.blank? || !known.include?(name)

      add('ar_column', name, owner, line)
    end

    def receiver_root(node)
      receiver = node.receiver
      receiver = receiver.receiver while receiver.is_a?(Prism::CallNode)

      case receiver
      when Prism::ConstantReadNode then receiver.name.to_s
      when Prism::ConstantPathNode then (receiver.full_name rescue nil).to_s
      end
    end

    # --- assignments --------------------------------------------------------

    # A hole `#{cond}` names a name rather than a value. For the question "what
    # gets in there" to become a query against the index, the second half is
    # needed: where something was assigned to that name.
    #
    # Not every assignment is written — otherwise the index bloats with exactly
    # what bloated the text search. The selection happens in flush_assigns.
    # The lines of the file where the query that filled this variable stands. The
    # call itself — plus the lines of the variables substituted into that call:
    # `sql = "select * from t"; res = select_all(sql)` — the table is named in the
    # first line while the result row is taken in the second.
    def row_origin_of(value)
      lines = (value.location.start_line..value.location.end_line).to_a
      variable_names_in(value).each { |name| lines.concat(@sql_var_lines[name] || []) }
      lines.uniq
    end

    def variable_names_in(node, out = [])
      case node
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        out << node.name.to_s
      end
      node.compact_child_nodes.each { |child| variable_names_in(child, out) }
      out
    end

    def note_assign(name, value, line, operator)
      return if value.nil?

      text, interpolated, merged, holes = literal(value)
      source = value.slice.to_s[0, 400]
      whole_sql = text.to_s.match?(SQL_START)
      part_sql = !whole_sql && text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)
      # The order matters: "carries a query" is about what was there BEFORE this
      # line.
      carrier = @sql_vars.include?(name)
      @sql_vars << name if whole_sql
      # The variable holds A RESULT ROW: `info = select_all(…).to_a`. Needed to
      # tell `row[field]` (a possible column read) from `ids[i]` (an ordinary
      # array access) — there are three times more of the latter in the tree.
      #
      # And at the same time — where it came from: through these lines of the
      # file a read learns its table. The query stands either right in the call
      # or in a variable it was assigned to above.
      @sql_var_lines[name] = (value.location.start_line..value.location.end_line).to_a if whole_sql
      if source.match?(@row_source)
        @row_vars << name
        @row_origin[name] = row_origin_of(value)
      end

      # A piece of a query appended to a variable that already carries one:
      # `sql << " where id in (#{ids})"`. Such a piece cannot be parsed as a
      # whole — it is not a statement at all — but the hole in it is the same one,
      # and its position in the query is readable. Without this parse the most
      # common way of assembling a query from pieces stayed invisible.
      record_holes(text, holes, line, blind: merged, carrier: name) if carrier && !whole_sql && holes.present?

      list, dups = column_list(value)
      if list
        detail = { columns: list, size: list.size }
        detail[:dups] = dups if dups.present?
        add('col_list', name, scope_name, line, detail: detail)
      end

      @assigns << {
        name: name, line: line, scope: scope_name, operator: operator, carrier: carrier,
        value: (text || source).to_s.gsub(/\s+/, ' ').strip[0, 200],
        sql: whole_sql, part: part_sql, literal: !text.nil?, interpolated: interpolated,
        # The value is not a string (`cond = build_cond`,
        # `online_sql = ReportSql.sql`) — we remember WHAT it is taken from:
        # through that name a hole reaches the method that fills it in two steps
        # instead of one.
        from: text.nil? ? (expr_call(source) || hole_root(source)) : nil,
        const: (text.nil? && hole_root(source).match?(/\A[A-Z]/) ? hole_root(source) : nil),
        holes: Array(holes).map { |hole| hole[:expr] }.first(4)
      }
      @sql_here ||= whole_sql
    end

    # A column list substituted into a query AS A WHOLE: `FIELDS = 'a,b,c'` or
    # `fields = %w[a b c]`. For such a column the list is the only place it is
    # named at all: its name does not appear in the parsed SQL, and without this
    # kind it looks dead. That is exactly where the first parse of one table gave
    # a wrong answer: 35 columns out of 71 live only through two such lists.
    #
    # A threshold of three familiar names filters out ordinary strings and
    # arrays: a random array may match column names in one or two words, but not
    # in three.
    COLUMN_LIST_MIN = 3

    def column_list(value)
      items =
        case value
        when Prism::ArrayNode then value.elements.filter_map { |element| literal(element)&.first }
        when Prism::StringNode then value.unescaped.scrub('').split(/[\s,]+/)
        end
      return nil if items.nil?

      names = items.map { |item| item.to_s.strip }.reject(&:empty?).select { |item| known.include?(item) }
      return nil if names.uniq.size < COLUMN_LIST_MIN

      # Duplicates are removed from the composition — consumers need the set of
      # columns — but they ARE REMEMBERED. A duplicate in a field list is not a
      # typo without consequences: in one field list a name appears twice, and
      # the place of its neighbour in the series is taken, which is why a column
      # is filled for 19,452 people and read by nobody. While duplicates were
      # silently merged there was nothing to check that mechanically with.
      dups = names.tally.select { |_, times| times > 1 }
      [names.uniq, dups]
    end

    APPEND_RECEIVERS = [Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode,
                        Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode].freeze

    # `sql << ' where id = 1'` — the variable accumulates a query from pieces.
    # This is the same assignment: without it `sql` would look like an empty
    # string in the index.
    def note_append(node)
      receiver = node.receiver
      return unless APPEND_RECEIVERS.any? { |klass| receiver.is_a?(klass) }

      argument = node.arguments&.arguments&.first
      note_assign(receiver.name.to_s, argument, node.location.start_line, '<<')
    end

    # A variable visible outside the file: @, @@, $ and a constant. A local one
    # cannot be tied to another file by anything, while these are exactly the ones
    # travelling between a controller, a model and a view.
    def cross_file_name?(name)
      name.start_with?('@', '$') || name.match?(/\A[A-Z]/)
    end

    # An assignment enters the index if at least one of these holds:
    #
    #   * the value looks like a query (`sql = "select …"`) — a finding in
    #     itself;
    #   * the name is substituted into an SQL hole, into a columnar-store call or
    #     into a render within the same file;
    #   * the name is visible beyond the file boundary (@, @@, $, a constant).
    #
    # The remaining local variables are noise: the code holds hundreds of
    # thousands of them and there is nothing to answer with them.
    # A table name is assembled in full from a variable — but the variable itself
    # is often assigned right there: `TABLE = 'board_replication'`,
    # `table = "#{prefix}_users"`. That is not a blind spot but a fact one step
    # away: of 137 such places 67 have the assignment in the same file. While the
    # step was missing the report honestly said "I do not know" where the answer
    # was right next to it.
    def resolve_table_holes
      blind = @refs.values.select do |ref|
        ref.kind == 'sql_blind' && ref.detail.is_a?(Hash) &&
          ref.detail[:error].to_s.include?('имя таблицы собрано интерполяцией целиком')
      end
      return if blind.empty?

      holes = @refs.values.select { |ref| ref.kind == 'sql_hole' && ref.owner == 'table' }
      values = @assigns.to_h { |assign| [assign[:name], assign[:value]] }

      blind.each do |ref|
        # A root recorded BY THE QUERY ITSELF is more reliable than a search by
        # line: in a heredoc the blind record sits on the starting line while the
        # hole sits on the line of the interpolation.
        root = ref.detail[:root].presence ||
               holes.find { |hole| hole.lines.intersect?(ref.lines) }&.token
        value = values[root]
        next if value.blank?

        # The value comes in three forms, and all three are alive:
        #   `'board_replication'`                       — a ready name;
        #   `slow? ? 'events_log2' : 'queries_log'`    — A CHOICE between two
        #     names: this is the most common pattern for switching a contour or a
        #     shard, and both names have to be named rather than recording the
        #     whole expression as "the table";
        #   `"#{prefix}_users"`                         — a prefix, there is no
        #     name.
        quoted = value.to_s.scan(/['"]([a-z_][a-z0-9_]*)['"]/i).flatten
        stem = value.to_s.gsub(SQL_HOLE, '').strip
        names = quoted.presence || (stem.match?(/\A[a-z_][a-z0-9_]*\z/i) ? [stem] : [])
        names = names.select { |name| name.length >= 3 && !@guess_stoplist.include?(name) }.uniq
        # If there are names among the candidates KNOWN from a schema snapshot,
        # only those are taken: in
        # `(@client_segment=='GLOM') ? 'big_users' : 'big_users_live'` the condition
        # value is quoted as well while being no table at all.
        schema_known = names.select { |name| known.include?(name) }
        names = schema_known if schema_known.any?
        next if names.empty?

        names.each do |name|
          add('pg_table_guess', name, '', ref.lines.first, detail: { via: "#{root} = #{value}" })
        end
        ref.detail[:resolved] = names.join(', ')
      end
    end

    def flush_assigns
      @assigns.each do |assign|
        next unless assign[:sql] || assign[:part] || assign[:carrier] ||
                    @wanted_roots.include?(assign[:name]) || cross_file_name?(assign[:name])

        add('assign', assign[:name], assign[:scope], assign[:line],
            detail: { value: assign[:value], sql: assign[:sql], part: assign[:part],
                      op: assign[:operator], literal: assign[:literal], carrier: assign[:carrier],
                      from: assign[:from], const: assign[:const], holes: assign[:holes] })
      end
      @assigns.clear
    end

    # A method that RETURNS a query is not the same as a method whose body
    # contains one: the second is true of almost any model, and by such a property
    # "SQL arrives in the hole" would find everything indiscriminately.
    #
    # The last expression of the body is examined, unwrapping the tail of calls:
    # the dominant form is `<<~SQL.squish`, and without unwrapping it reads as a
    # call rather than as a string. A branch at the end
    # (`if a then sql1 else sql2 end`) does not land here — that is a known
    # undercount, and undercounting beats inviting every model method into the
    # report.
    # => 'whole' | 'part' | nil
    def sql_return_kind(node)
      body = node.body
      last = body.is_a?(Prism::StatementsNode) ? body.body.last : nil
      last = last.receiver while last.is_a?(Prism::CallNode) && last.receiver
      case last
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        @sql_vars.include?(last.name.to_s) ? 'whole' : nil
      else
        text, = literal(last)
        return 'whole' if text.to_s.match?(SQL_START)
        # `ReportSql.sql` returns `(user_id in (select …))` — not a statement but
        # a ready condition. For a hole there is no difference: a piece of a query
        # will be substituted.
        return 'part' if text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)

        nil
      end
    end

    # The names of a method's parameters. If the root of a hole is a parameter,
    # the source has to be looked for at the caller, and the report is obliged to
    # say so rather than stay silent.
    def parameter_names(node)
      params = node.parameters
      return [] if params.nil?

      %i[requireds optionals keywords].flat_map { |kind| params.respond_to?(kind) ? params.send(kind) : [] }
        .filter_map { |p| p.respond_to?(:name) && p.name ? p.name.to_s : nil }
        .concat([params.respond_to?(:rest) && params.rest.respond_to?(:name) ? params.rest&.name.to_s : nil].compact)
        .reject(&:empty?)
    end

    def scope_name
      klass = @scope_stack.reject(&:empty?).join('::')
      return klass if @method.nil?

      klass.empty? ? @method.to_s : "#{klass}#{@method}"
    end

    def constant_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then (node.full_name rescue node.name.to_s).to_s
      else ''
      end
    end

    # Wrappers over thrift whose first argument is the table name.
    #
    # The list is explicit rather than "everything starting with hb_": by prefix
    # `hb_mail_info('new', …)` landed here, where the first argument is a mail
    # folder, and the index acquired columnar-store tables `new`, `clean`,
    # `friends`. A new wrapper will have to be added here by hand — that is
    # cheaper than cleaning out invented names.

    def hbase_call?(node)
      name = node.name.to_s
      return false unless @table_first.include?(name)
      return true if name.start_with?('hb_')

      # `increment` and `atomic_incr_when_error` are common names, so only with
      # an explicit constant receiver of the columnar-store wrapper.
      recv = node.receiver
      recv.is_a?(Prism::ConstantReadNode) && recv.name.to_s.include?('Hbase')
    end

    # The expressions from the holes as one line — for records where the
    # position within the string does not matter while what the name is assembled
    # from does: a columnar-store table name, a column qualifier.
    def hole_list(holes)
      Array(holes).map { |hole| hole[:expr] }.reject(&:blank?).uniq.join(' + ')
    end

    # => [text, was_there_interpolation, did_a_hole_glue_to_a_name, holes]
    #
    # A hole is [{ expr: 'ids.join(",")', offset: 42 }]: what gets interpolated
    # and into which place of the assembled text. Previously only `$1` came back
    # from here, and the expression was lost for good.
    def literal(node)
      case node
      when Prism::StringNode
        [node.unescaped.scrub(''), false]
      when Prism::SymbolNode
        [node.unescaped.scrub(''), false]
      when Prism::InterpolatedStringNode
        interpolated = false
        merged = false
        holes = []
        text = +''
        node.parts.each do |part|
          case part
          when Prism::StringNode
            chunk = part.unescaped.scrub('')
            merged ||= text.end_with?(SQL_HOLE) && chunk.match?(IDENT_HEAD) && !inside_string_literal?(text)
            text << chunk
          when Prism::InterpolatedStringNode
            # Adjacent literals glued by a line continuation (`"a " \` / `"b"`)
            # are returned by Prism as nested nodes. Previously such a piece
            # counted as one hole in its entirety: `"… VALUES " "(#{a}, #{b})"`
            # produced `… VALUES $1`, that is, half the query simply vanished and
            # it went into the blind spots. They are unwrapped and the hole
            # offsets shifted.
            inner, inner_interpolated, inner_merged, inner_holes = literal(part)
            interpolated ||= inner_interpolated
            merged ||= inner_merged
            merged ||= text.match?(IDENT_TAIL) && inner.start_with?(SQL_HOLE) && !inside_string_literal?(text)
            merged ||= text.end_with?(SQL_HOLE) && inner.match?(IDENT_HEAD) && !inside_string_literal?(text)
            Array(inner_holes).each do |hole|
              holes << hole.merge(offset: text.length + hole[:offset])
            end
            text << inner
          else
            interpolated = true
            merged ||= text.match?(IDENT_TAIL) && !inside_string_literal?(text)
            # A hole has a line of its own rather than the start of the literal:
            # for a `%|SELECT …|` spanning six lines every hole would be shown on
            # the first, and finding them in the file would be impossible.
            holes << { expr: hole_expression(part), offset: text.length,
                       line: part.location.start_line }
            text << SQL_HOLE
          end
        end
        [text, interpolated, merged, holes]
      end
    end

    # The source text of the expression from `#{...}` (and from the old form
    # `#@ivar`).
    def hole_expression(part)
      text = part.slice.to_s
      text = text.start_with?('#{') ? text[2..-2].to_s : text.sub(/\A#/, '')
      text.gsub(/\s+/, ' ').strip
    end

    IDENT_HEAD = /\A[A-Za-z0-9_$]/
    IDENT_TAIL = /[A-Za-z0-9_$]\z/
    private_constant :IDENT_HEAD, :IDENT_TAIL

    # A rough check for "we are inside an SQL string literal": inside quotes the
    # concatenation `'%$1%'` is harmless, while `tbl$1` outside them is already
    # an invented name.
    def inside_string_literal?(text)
      text.count("'").odd?
    end

    # --- views --------------------------------------------------------------

    # `render 'x/y'`, `render partial: 'x/y'`, `render(partial: "x/y", ...)`.
    # Parsed line by line rather than with Prism: in an .erb file the Ruby is
    # sliced up by tags and there is no whole tree there.
    # Forms: `render 'x'`, `render partial: 'x'`, `render :partial=>'x'`,
    # `render(:partial => "/x/y")`. The dominant one is the old one, with the
    # arrow — the first version of the pattern did not know it and lost two
    # thirds of the calls.
    #
    # Three outcomes for one call, and the difference between them is the
    # difference between a fact and a guess:
    #
    #   render_ref                      the view name stands in the code in full.
    #                                   A fact.
    #   render_dynamic (owner=skeleton) the name is assembled by interpolation,
    #                                   but the literal pieces are there:
    #                                   `"theme_old/layouts/#{p}"`. A pattern is
    #                                   built from them, and through the pattern
    #                                   CANDIDATE edges are issued.
    #   render_dynamic (owner='')       the name sits entirely in a variable. An
    #                                   honest blind spot: there is nothing to
    #                                   say about it beyond the fact that it is
    #                                   there.
    #
    # Previously an interpolated call landed nowhere: the index did not say "I do
    # not know", it stayed silent, and the silence read as "there are no links".
    # The site's production menu (half a million renders a day) was listed as
    # unreachable.

    RENDER_WORD = /\brender\b/

    # `render` in a call position rather than in page text or in a comment.
    # Previously there was no check at all, and comments ("-- render avatar
    # p=a#{...}" out of a banner file) and hint strings from specs landed in the
    # blind spots. The dot in the list is for
    # `ApplicationController.render(partial: …)`: a render from a class rather
    # than from a view.
    CALL_PREFIX = /(?:\A|[=({\[,|&;+%?.]|\b(?:and|or|then|do|else|return|yield)\b)\s*\z/

    # `:partial=>`, `partial:`, `:template =>` — the keys a view stands behind.
    # ALL of those present in the call are taken: `render :layout=>'a',
    # :template=>b` names two views at once, and the second does not cancel the
    # first.
    VIEW_KEY = /(?::(?:partial|template|layout)\s*=>|\b(?:partial|template|layout)\s*:)\s*/
    # Any keyword argument: `json:`, `plain:`, `:status=>`.
    ANY_KEY = /\A(?::[a-z_]+\s*=>|[a-z_]+\s*:(?!:))\s*/

    # The start of a target expression: `@partial`, `acts`,
    # `bootstrap_partial_path`.
    EXPR_HEAD = /\A[@$]{0,2}[A-Za-z_][A-Za-z0-9_]*[!?]?/

    # `render :layout=>false`, `render nil` — that cannot be called a view
    # target.
    NOT_A_TARGET = %w[false true nil self and or if unless return].freeze

    # A view name in its static form — the same as before: letters, digits,
    # underscore and slash only. Anything else is not a logical view name.
    STATIC_TARGET = %r{\A[a-z0-9_/]+\z}i

    # --- javascript ---------------------------------------------------------

    # The last language the index could not see. 431 files sat in the index and
    # yielded only word matches, so the reachability graph broke off at
    # `app/javascript` and the chain "template → controller → its method" did not
    # exist at all — while `data-controller` appears in 1,022 templates.
    # A stylesheet: what it declares and what it includes. The parse is partial
    # deliberately (see Xref::Css): classes, imports and `@apply` are what is
    # needed.
    def scan_css
      Xref::Css.elements(source).each do |element|
        case element.kind
        when 'class' then add('css_class', element.name, '', element.line)
        when 'id' then add('css_id', element.name, '', element.line)
        # `@apply` is a USE of the class by the stylesheet itself: a class
        # folded into a utility may be unnecessary to the markup while its rule
        # is alive.
        when 'apply' then add('css_apply', element.name, '', element.line)
        when 'import'
          resolved = Xref::Css.resolve(path, element.name)
          if resolved
            add('css_import', resolved, '', element.line)
          elsif Xref::Css.package?(element.name)
            # `@import 'tailwindcss'`,
            # `@import 'bootstrap/dist/css/bootstrap.css'` — that is a PACKAGE
            # from node_modules rather than a path in the tree. While they went
            # into "leads nowhere", the report called eleven live build lines
            # broken: all eleven were packages.
            add('css_package', element.name, '', element.line)
          else
            add('css_import_missing', element.name, '', element.line)
          end
        end
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    # Classes mentioned by THE MARKUP and by THE CODE. Four routes, and each is
    # needed: without any one of them a declared class looks unused.
    CLASS_ATTR = /\bclass(?:Name)?\s*=\s*(["'])(.*?)\1/m
    # `class: 'btn'`, `class: "btn #{kind}"` — that is how helpers write a class.
    CLASS_OPTION = /\bclass:\s*(["'])(.*?)\1/m
    # Code at runtime: `classList.add('x')`, `$(el).addClass('x y')`.
    CLASS_CALL = /\.(?:add|remove|toggle|contains|addClass|removeClass|toggleClass)\(\s*(["'])([^"']+)\1/
    # Stimulus: `data-controller-class="x"` and `data-...-classes`.
    CLASS_DATA = /\bdata-[a-z0-9-]+-classe?s?=\s*(["'])([^"']+)\1/
    CLASS_WORD = /\A-?[A-Za-z_][A-Za-z0-9_-]*\z/

    def scan_class_usage
      source.each_line.with_index(1) do |row, line|
        [CLASS_ATTR, CLASS_OPTION, CLASS_DATA].each do |pattern|
          row.scan(pattern) { note_class_list(Regexp.last_match(2), line) }
        end
        row.scan(CLASS_CALL) { note_class_list(Regexp.last_match(2), line) }
        note_pack_refs(row, line)
      end
    end

    # A list of classes from one place. Literals are a fact; an assembled part
    # is a blind spot, but it sometimes has a PATTERN (`btn-$1`), and a class is
    # findable through a pattern.
    # THE PACK NAME, named by a template or by a helper. That is how a page gets
    # its stylesheet: `modern_stylesheet_pack_tag 'theme_new'`,
    # `esbuild_pack_asset_path('photo_swipe.css')`. Without this record the chain
    # "contour → pack → build entry → file" does not close, and the question "is
    # there a rule for this class IN THIS CONTOUR" stays unanswered.
    PACK_CALL = /(?:stylesheet_pack_tag|javascript_pack_tag|pack_asset_path|pack_tag)\s*\(?\s*(["'])([^"']+)\1/
    PACK_DYNAMIC = /(?:stylesheet_pack_tag|javascript_pack_tag|pack_asset_path|pack_tag)\s*\(?\s*["'][^"']*\#\{/

    def note_pack_refs(row, line)
      row.scan(PACK_CALL) do
        name = Regexp.last_match(2).sub(/\.(?:css|js|scss)\z/, '')
        add('pack_ref', name, '', line) if name.match?(/\A[A-Za-z_][\w.-]*\z/)
      end
      add('pack_dynamic', 'имя пака собрано', '', line) if row.match?(PACK_DYNAMIC)
    end

    def note_class_list(text, line)
      # THE ORDER DECIDES: first the interpolations are masked, then the split by
      # spaces happens. The other way round `class="btn btn-<%= kind %>"` fell
      # apart into `<%=`, `kind`, `%>` — and `kind` entered the index as a CLASS
      # that does not exist in the styles at all.
      masked = text.to_s.gsub(/<%.*?%>/m, SQL_HOLE).gsub(/\#\{[^}]*\}/, SQL_HOLE)
      masked.split(/\s+/).reject(&:empty?).each do |word|
        if !word.include?(SQL_HOLE)
          add('html_class', word, '', line) if word.match?(CLASS_WORD)
        elsif word.delete(SQL_HOLE).match?(/[A-Za-z0-9]{2}/)
          # `btn-$1` is a pattern: a declared class is findable through it.
          add('html_class_pattern', word[0, 60], '', line,
              detail: { glob: like_pattern(word.tr(SQL_HOLE, '*')) })
        else
          # The name is assembled in full — the honest blind spot of this layer.
          add('html_class_dynamic', text.to_s.strip[0, 60], '', line)
        end
      end
    end

    def scan_js
      Js.elements(source).each do |element|
        case element.kind
        when 'import' then note_js_import(element)
        when 'export' then add('js_export', element.name.to_s, '', element.line) if element.name.present?
        when 'class'
          # `extends Controller` is the sign of a Stimulus controller. A class
          # also comes anonymous
          # (`module.exports = class extends Controller {`), and then the name is
          # taken from the file: what links them is the registration anyway.
          name = element.name.presence || File.basename(path, File.extname(path)).camelize
          add('js_class', name, element.detail.to_s, element.line)
          add('stimulus_class', name, '', element.line) if element.detail.to_s.end_with?('Controller')
        when 'register' then add('stimulus_register', element.name, element.detail.to_s, element.line)
        # An attachment from code is as much an attachment as an attribute in a
        # template, and the report is obliged to count it as one: otherwise a
        # controller attached by an initialiser is listed as dead.
        when 'attach' then add('stimulus_use', element.name, 'js', element.line)
        when 'target' then add('stimulus_target', element.name, '', element.line)
        when 'value' then add('stimulus_value', element.name, element.detail.to_s, element.line)
        when 'class_name' then add('stimulus_css_class', element.name, '', element.line)
        when 'outlet' then add('stimulus_outlet', element.name, '', element.line)
        when 'method' then add('js_method', element.name, '', element.line)
        # A top-level function and a call site. A name is A POOR KEY (as in
        # Ruby), so a call is a hook rather than a fact, and the report says so.
        when 'function' then add('js_func', element.name, scope_name, element.line)
        when 'call' then add('js_call', element.name, '', element.line)
        # An import binding: through it we count WHETHER the library is still
        # called. There is no need to go inside a library — "unused" is the
        # majority in there by construction, and one throws it out by version
        # rather than by rule.
        when 'binding'
          mentions = source.scan(/(?<![.\w$])#{Regexp.escape(element.name)}(?![\w$])/).size
          add('js_binding', element.name, element.detail.to_s, element.line,
              detail: { mentions: mentions })
        # A build root from the bundler config (`entryPoints: [...]`). A file
        # nobody imports because it is RUN is an entry point rather than a
        # removal candidate; `package.json` names only the config itself, so
        # without this parse the real roots were listed as dead.
        when 'entry'
          if File.file?(Xref.root.join(element.name))
            # The `detail` of an entry carries THE PACK NAME, while for an
            # assembled path it carries the mark "assembled from parts". While
            # these were not told apart, the mark landed in the name field and the
            # "pack → entry" link by naming convention was never found once (632
            # classes of a contour stayed unanswered).
            assembled = element.detail == 'собран из частей'
            add('js_entry', element.name, 'bundler', element.line,
                detail: { pack: (element.detail.presence unless assembled), assembled: assembled }.compact)
          end
        end
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    # A module edge. The path in a `require` is written without an extension, so
    # the target is resolved against the files; where it did not resolve, that is
    # a separate class rather than an edge: an external dependency
    # (`@hotwired/stimulus`) and a typo in a path are different things and must
    # not be mixed.
    def note_js_import(element)
      target = element.name.to_s
      if target.start_with?('.')
        resolved = Js.resolve(path, target)
        if resolved
          add('js_import', resolved, '', element.line)
        else
          add('js_import_missing', target, '', element.line)
        end
      else
        add('js_package', target.split('/').first(target.start_with?('@') ? 2 : 1).join('/'),
            '', element.line)
      end
    end

    # --- front-end configuration --------------------------------------------

    # Four rules, each from an incident. The report is obliged to print them out
    # loud: in a front-end config an error does not fail, it quietly starts
    # serving the wrong thing.
    # The directives that ARE LOST when the location is re-selected. Without them
    # `rewrite … last` is the normal and only way to rewrite a path, and
    # declaring it a defect means issuing 25 findings where there are none.
    CONF_GUARDS = %w[limit_conn limit_req add_header expires proxy_hide_header].freeze
    def scan_nginx
      elements = Nginx.elements(source)
      # What stands in each location — needed to judge `rewrite … last`: on its
      # own it is harmless, and the trouble starts where THE SAME location also
      # holds a limit or a header.
      guards = elements.select { |e| e.kind == 'directive' && CONF_GUARDS.include?(e.name) }
                       .group_by(&:scope)

      elements.each do |element|
        if element.kind == 'block'
          add('conf_block', element.args.presence || element.name, element.name, element.line,
              detail: { scope: element.scope.presence }.compact)
          next
        end

        add('conf_directive', element.name, element.args.to_s[0, 200], element.line,
            detail: { scope: element.scope.presence }.compact)
        note_nginx_defect(element, guards)
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    def note_nginx_defect(element, guards)
      case element.name
      when 'server_name'
        if Nginx.unanchored_server_name?(element.args)
          add('conf_defect', 'регулярка вхоста без якорей', element.args.to_s[0, 120], element.line)
        end
      when 'rewrite'
        # The condition is twofold, and the second part matters more than the
        # first: re-selecting the location is NORMAL, the trouble is losing the
        # guards of your own location while doing it.
        lost = guards[element.scope].to_a.map(&:name).uniq
        if Nginx.rewrite_restarts?(element.args) && element.scope.to_s.include?('location') && lost.any?
          add('conf_defect', 'rewrite … last теряет сторожей своей локации',
              "#{lost.join(', ')} в «#{element.scope}»"[0, 120], element.line,
              detail: { rule: element.args.to_s[0, 120] })
        end
      when 'proxy_next_upstream'
        if Nginx.next_upstream_doubles?(element.args)
          add('conf_defect', 'http_404 в proxy_next_upstream удваивает 404', element.args.to_s[0, 120],
              element.line)
        end
      when 'add_header'
        # An own header does NOT replace an upstream one: without
        # `proxy_hide_header` both travel, and the one from the backend wins.
        if element.args.to_s.match?(/\ACache-Control\b/i) && !source.match?(/proxy_hide_header\s+Cache-Control/i)
          add('conf_defect', 'add_header Cache-Control без proxy_hide_header', element.args.to_s[0, 120],
              element.line)
        end
      end
    end

    # --- shell scripts ------------------------------------------------------

    # The `.sh` files hold what production depends on, and the index knew not a
    # single fact from them. An environment key read by a script is as much a
    # read as one from Ruby: the report "the key is read while the environment
    # lacks it" is obliged to see both.
    #
    # A query from a heredoc is parsed by THE SAME parser as in Ruby files. That
    # is the whole point: `psql <<SQL … SQL` in a deploy script touches the same
    # tables, and "who touches this table" answers incompletely without the
    # scripts.
    def scan_shell
      elements = Shell.elements(source)
      # THE DISTINCTION without which the environment report becomes garbage.
      # `$arg`, `$path`, `$h`, `$cached` are variables of the script itself
      # rather than environment keys, and the tree holds more of them than of the
      # real ones. The sign is simple and precise: an environment key is one the
      # script READS WITHOUT ASSIGNING.
      #
      # There is one exception and it is idiomatic: `VAR=${VAR:-default}` both
      # assigns and reads — that is exactly a read of the environment with a
      # fallback.
      assigned = elements.select { |e| %w[assign bound].include?(e.kind) }.to_set(&:text)
      own_default = elements.select { |e| e.kind == 'variable' && e.extra[:default] }
                            .select { |e| elements.any? { |a| a.kind == 'assign' && a.text == e.text && a.line == e.line } }
                            .to_set(&:text)

      elements.each do |element|
        case element.kind
        when 'variable'
          # The name of a shell variable and the name of an environment key are
          # the same thing: `$DB_HOST` in a script and `ENV['DB_HOST']` in Ruby
          # read the same.
          # The second condition is THE CASE. An assignment is not always
          # caught: a name may receive its value inside a heredoc which travels
          # to a node in its entirety, and then only the read is visible from
          # outside. But an environment key in this tree (and by general shell
          # custom) is written in CAPITALS, while `sha`, `img`, `path` are
          # variables of the script. Without this rule 111 names out of 442
          # landed among the "environment keys".
          local = (assigned.include?(element.text) && !own_default.include?(element.text)) ||
                  element.text != element.text.upcase
          if local
            add('sh_var', element.text, '', element.line)
          else
            add(element.extra[:default] ? 'env_default' : 'env_key', element.text, '', element.line)
          end
        when 'assign', 'bound'
          add('sh_assign', element.text, '', element.line)
        when 'command'
          add('sh_command', element.text, '', element.line,
              detail: { line: element.extra[:line_text] })
        when 'dangerous'
          add('sh_dangerous', element.text, '', element.line)
        when 'heredoc'
          note_shell_heredoc(element)
        end
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    # The body of a heredoc is most often a query. For the SQL parser shell
    # interpolations are the same holes as `#{…}` in Ruby, and they are replaced
    # the same way.
    def note_shell_heredoc(element)
      text = element.text.to_s
      return if text.strip.empty?

      add('sh_heredoc', element.extra[:tag].to_s, '', element.line,
          detail: { lines: text.lines.size })
      return unless text.match?(SQL_START)

      prepared = text.gsub(Shell::VARIABLE, SQL_HOLE)
      analyze_sql(prepared, element.line)
    end

    # --- configuration: yaml and json ---------------------------------------

    # The main thing here is the ERB inside yaml. Through it our configuration
    # files read environment keys (`config/database.yml`, `cable.yml`,
    # `storage.yml`), and while yaml went unparsed those reads were invisible
    # entirely: the report "the code reads a key the environment lacks" stayed
    # silent about them.
    #
    # They are parsed by THE SAME walk as Ruby files — there must be no separate
    # branch, otherwise the rules drift apart silently.
    #
    # Translations are not touched here: the locale directories are already
    # parsed in their own way (Xref::Locales), and their keys come by the
    # thousand per file.
    def scan_structured
      walk_ruby(Erb.ruby(source)) if File.extname(path) != '.json' && source.include?('<%')
      return if path.match?(@locale_dirs)

      tree = Structured.parse(path, source)
      return if tree.nil?

      if Structured.compose?(path, tree)
        note_compose(tree)
        return
      end

      note_conf_keys(tree)
      note_package(tree) if File.basename(path) == 'package.json'
      note_artifact(tree) if path.start_with?('doc/')
    end

    # Key paths: a question about a configuration file is asked with a path
    # (`production.primary.host`) rather than with a word. VALUES are never
    # recorded — in a configuration file that is a password, an address or a key,
    # and they have no place in the index.
    # An inventory of a past task is an OUTCOME rather than a configuration
    # file, and the questions about it are different. Its full key tree yielded
    # 42,945 records out of 593 files: twenty thousand names of the form
    # `rows.0.status_semantics` that nobody will ever ask about. For such files
    # the schema name and the top tier are taken — by them the artefacts of a
    # task are grouped together, and beyond that one has to read the file itself.
    ARTIFACT_DIR = %r{\Adoc/schema/}
    def note_conf_keys(tree)
      depth = path.match?(ARTIFACT_DIR) ? 1 : Structured::MAX_DEPTH
      Structured.key_paths(tree, [], [], depth: depth).each { |key| add('conf_key', key, '', 1) }
    end

    # The composition of services. Four questions, each of which has cost an
    # incident once: which image, which environment keys, what is mounted, which
    # port is published.
    def note_compose(tree)
      Structured.compose_services(tree).each do |service|
        add('compose_service', service[:service], service[:image], 1)
        service[:env].each { |name| add('compose_env', name, service[:service], 1) }
        service[:mounts].each { |mount| add('compose_mount', mount, service[:service], 1) }
        service[:ports].each { |port| add('compose_port', port, service[:service], 1) }
      end
    end

    def note_package(tree)
      %w[dependencies devDependencies].each do |section|
        next unless tree[section].is_a?(Hash)

        tree[section].each_key { |name| add('js_dependency', name.to_s, section, 1) }
      end

      # Build commands are THE ONLY place where the roots nobody imports and
      # which are run directly are named: `node config/esbuild.mjs`. Without them
      # the bundler config itself was listed as a removal candidate. Only the
      # path is taken: the rest of the command is as much a configuration value
      # as a password.
      return unless tree['scripts'].is_a?(Hash)

      tree['scripts'].each_value do |command|
        command.to_s.scan(%r{[\w./-]+\.(?:js|mjs|cjs)\b}) do |candidate|
          next unless File.file?(Xref.root.join(candidate))

          add('js_entry', candidate, 'package.json', 1)
        end
      end
    end

    # A task inventory: `doc/schema/*.json` is the outcome of past work, and it
    # has a schema name. By it the artefacts of one task are grouped together,
    # and the question "what has already been looked into about this table" gets
    # an answer.
    def note_artifact(tree)
      return unless tree.is_a?(Hash)

      version = tree['schema_version'] || tree['schema'] || tree['version']
      add('artifact_schema', version.to_s[0, 120], '', 1) if version.is_a?(String) && version.present?
    end

    # --- markdown -----------------------------------------------------------

    # A document is as much a source of statements about the tree as code is, and
    # its statements age SILENTLY. It is parsed by a real parse (Xref::Markdown),
    # and the code blocks inside it by the same parsers as files: a query in a
    # document that does not parse is an example nobody ever ran.
    #
    # The record kinds here are its own (`doc_*`), and that is the main decision.
    # A mention of a table in a document is NOT an access to the table: mixing
    # them means declaring used whatever has merely been written about. The
    # reports add them up separately.
    DOC_SPAN_MAX = 120
    def scan_markdown
      Markdown.elements(source).each do |element|
        case element.kind
        when 'heading' then note_doc_heading(element)
        when 'link' then note_doc_link(element)
        when 'span' then note_doc_span(element)
        when 'code' then note_doc_code(element)
        end
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    # Headings of the first two levels: these are SECTIONS, and through them an
    # answer points at a place in a document. The third level and below do not
    # enter the index — our documents run to two and a half thousand lines, and a
    # fine-grained split would yield a hundred records per file to no benefit.
    def note_doc_heading(element)
      return if element.extra[:level] > 2 || element.text.length > 200

      add('doc_heading', element.text, element.extra[:level].to_s, element.line)
    end

    # A link. The class decides everything: a link to a file that does NOT exist
    # is a finding (and our documentation accumulates such links), a link
    # outwards is simply a URL, and an anchor inside a document has nothing to be
    # checked against.
    def note_doc_link(element)
      target = element.text.to_s
      return if target.empty? || target.length > 300

      kind =
        if target.start_with?('http://', 'https://', 'mailto:') then 'адрес'
        elsif target.start_with?('#') then 'якорь'
        # A wiki link to a memory note not yet written is not an error but A
        # MARK: that is how one registers something worth writing down later. A
        # separate word, so that such links do not land among the findings
        # together with the genuinely broken ones.
        elsif element.extra[:wiki] then wiki_exists?(target) ? 'памятка' : 'памятка не написана'
        else
          resolved = resolve_doc_path(target)
          if resolved then 'файл'
          # An absolute path that does not exist is not a finding: 617 links out
          # of 632 are built that way, and 524 of them lead into a working
          # directory that is not versioned and does not exist in somebody
          # else's copy of the tree at all. Calling that a broken link means
          # drowning fifteen real ones in six hundred expected ones.
          elsif target.start_with?('/') then 'вне дерева'
          # A link in a document, unlike a mention in backticks, is relative to
          # the document itself — so anchoring to the root is not required here:
          # the target is next to it or it does not exist.
          elsif target.match?(%r{\A[\w./-]+\z}) then 'НЕТ ТАКОГО ФАЙЛА'
          else 'не разобрана'
          end
        end
      token = kind == 'файл' ? resolve_doc_path(target) : target.split('#').first.to_s
      add('doc_link', token.presence || target, kind, element.line,
          detail: { label: element.extra[:label] }.compact)
    end

    # A path in a document is written relative to THE ROOT of the tree (that is
    # the custom here) or relative to the document itself. Both are checked:
    # otherwise a third of the links would be listed as broken out of nothing.
    def resolve_doc_path(target)
      bare = target.split('#').first.to_s
      return nil if bare.empty?

      return nil if bare.start_with?('~')

      candidates = [bare]
      candidates << File.join(File.dirname(path), bare) unless bare.start_with?('/')
      candidates.map { |candidate| File.expand_path(candidate, Xref.root.to_s) }
                .zip(candidates)
                .find { |full, _| File.exist?(full) }
                &.last
                &.then { |found| found.start_with?('/') ? found.delete_prefix('/') : found }
                &.then { |found| Pathname.new(found).cleanpath.to_s }
    end

    # The memory notes lie next to their index, and a link to them is written
    # without an extension.
    def wiki_exists?(target)
      !resolve_doc_path("#{target}.md").nil? ||
        !resolve_doc_path(File.join(File.dirname(path), "#{target}.md")).nil?
    end

    # Backticks are a deliberate naming. Three classes: a path in the tree
    # (existing or not), a name from the database, everything else (which does
    # not enter the index).
    def note_doc_span(element)
      text = element.text
      return if text.length > DOC_SPAN_MAX

      if Markdown.path_like?(text)
        resolved = resolve_doc_path(text)
        # "No such file" is asserted ONLY about a path anchored to the root of
        # the tree. Otherwise every illustrative example in the documentation
        # would become a broken link, and the real ones would drown in the
        # invented.
        owner = if resolved then 'есть'
                elsif Markdown.rooted?(text) then 'НЕТ ТАКОГО ФАЙЛА'
                else 'похоже на путь'
                end
        add('doc_path', resolved || text, owner, element.line)
      elsif known.include?(text)
        add('doc_name', text, '', element.line)
      end
    end

    # A code block is parsed by THE SAME parser as files of that language.
    # Otherwise an example in the documentation is text nobody knows whether it
    # works: our guide holds a schema of 42 views, and its executability used to
    # be checked by hand.
    def note_doc_code(element)
      lang = element.extra[:lang].to_s
      add('doc_code', lang.presence || 'без языка', '', element.line,
          detail: { lines: element.extra[:lines], unclosed: element.extra[:unclosed] }.compact)
      # A sketch with human omissions (`…`, `<node number>`) cannot and need not
      # be parsed: it is not supposed to run. This is THE FIRST check, otherwise
      # such blocks go into "broken examples" and drown the real findings: of 110
      # "broken" ones almost all were sketches.
      if sketch_block?(element.text)
        add('doc_code_sketch', lang.presence || 'без языка', '', element.line)
        return
      end

      # The language label lies more often than one would think: a block labelled
      # `ruby` holding a query occurs in our documents constantly. We trust THE
      # CONTENT rather than the label.
      lang = 'sql' if %w[ruby rb erb].include?(lang) && element.text.to_s.lstrip.match?(SQL_START)

      case lang
      when 'sql', 'postgresql', 'psql' then note_doc_sql(element)
      when 'ruby', 'rb' then note_doc_ruby(element)
      # A template is parsed THROUGH the assembly of Ruby from its tags rather
      # than with Prism directly: an `erb` block in a document is most often
      # markup without a single tag, and Prism honestly says of it "unexpected
      # '<'". That is not a broken example, that is HTML.
      when 'erb' then note_doc_ruby(element, erb: true)
      end
    end

    # A block with a patch is not code. Lines starting with `-`/`+` are a diff,
    # and parsing it as Ruby is meaningless: of 92 "broken Ruby examples" half
    # turned out to be patches. A report that calls them defects is a false
    # alarm, and a false alarm devalues the real findings.
    PATCH_LINE = /\A[-+](?![-+])/
    def patch_block?(text)
      body = text.to_s
      marked = body.lines.count { |row| row.match?(PATCH_LINE) }
      return true if marked >= 2
      return false if marked.zero?

      # A ONE-LINE patch: `def foo` as a context line (with a leading space) and
      # one line with `+`. Two markers will never accumulate here, while a diff
      # is exactly that.
      #
      # It is decided BY EXECUTION rather than by appearance: the first character
      # of every line is stripped and we look at whether the markers themselves
      # stopped being the cause of the failure. What is stripped rarely becomes
      # whole Ruby — people quote the middle of a method, with no `end` — so an
      # error of the "fragment" class qualifies as well. Without this check the
      # line `-1` in ordinary code would declare a block to be a patch.
      return false if Prism.parse(body).success?

      stripped = Prism.parse(body.lines.map { |row| row.sub(/\A[-+ ]/, '') }.join)
      stripped.success? || stripped.errors.first&.message.to_s.match?(EXCERPT_ERROR) || false
    end

    # A fragment of A HASH: the block consists entirely of `'key' => value`
    # pairs. That is how two lines from the middle of a literal get quoted, and
    # by construction it is a fragment rather than a defect of the example. It is
    # decided BY THE COMPOSITION of the block rather than by the text of the
    # parse error: Prism's message here is the same as for a genuine typo.
    HASH_ENTRY_LINE = /\A\s*(?:'[^']*'|"[^"]*"|:?[\w?!]+)\s*(?:=>|:)\s*\S/
    def hash_excerpt?(text)
      lines = text.to_s.lines.map(&:strip).reject { |row| row.empty? || row.start_with?('#') }
      lines.size >= 2 && lines.all? { |row| row.match?(HASH_ENTRY_LINE) }
    end

    # An omission made by a human: an ellipsis as one character, or a name in
    # angle brackets with a space or non-Latin letters inside (`<node number>`).
    # Neither occurs in executable code, and neither parses — which means "did
    # not parse" reports nothing about such a block.
    SKETCH_MARK = /…|<[^<>\n]*(?:\s|[\p{Cyrillic}])[^<>\n]*>/
    # An ellipsis line: dots only, sometimes with an explanation. That is how
    # documents mark a cut-out middle, and there is nothing further to parse.
    ELLIPSIS_LINE = /^\s*(?:#\s*)?\.{3}\s*(?:#.*)?$/
    # A listing of PLACES rather than code: lines of the form
    # `goals.rb:350   goal_ar.concat(…)`. That is how plans write out where
    # exactly the thing under discussion lies, and parsing it as Ruby is
    # meaningless — `goals.rb:350` reads there as an invalid character.
    PLACE_LINE = %r{^\s*[\w/.-]+\.(?:rb|erb|js|rake|sql|yml):\d+}
    # The same listing of places but WITHOUT the file name: the file is named in
    # the paragraph text and the lines start with a bare number
    # (`:165   fin = … || [1,2,3]`). Ruby reads `:165` as an invalid character,
    # and the block landed among the broken examples.
    LINE_NUMBER_LINE = /^\s*:\d+(?:[-–]\d+)?\s/
    def sketch_block?(text)
      body = text.to_s
      return true if body.match?(SKETCH_MARK) || body.match?(ELLIPSIS_LINE)

      lines = body.lines.map(&:strip).reject(&:empty?)
      return false if lines.size < 2

      lines.count { |row| row.match?(PLACE_LINE) } >= 2 ||
        lines.count { |row| row.match?(LINE_NUMBER_LINE) } >= 2
    end

    # Parse errors that mean A FRAGMENT rather than a defect: a quotation of code
    # breaks off mid-branch, and Prism honestly says it expected a continuation.
    # Calling that a broken example is a false alarm.
    EXCERPT_ERROR = /
      end-of-input | unexpected\s'(?:end|when|elsif|else|rescue|ensure|then)' |
      expected\san\sexpression\safter\sthe\soperator |
      parent\smethod\sis\snot\sforwarding | cannot\sparse\sthe\sexpression
    /x

    # Queries from a block go as separate kinds (`doc_table`, `doc_column`): this
    # is A MENTION rather than an access. Each statement is parsed separately, so
    # that one unparsed line does not take the whole block with it.
    # The prefixes a FRAGMENT of a query is completed into a statement with.
    # Documents quote fragments all the time (`from a join b where …` — half a
    # condition, which is what the text is about), and calling them broken
    # examples is a false alarm: of 45 "broken SQL" blocks almost all were those.
    # `create table ` is there because the composition of a table is written in
    # plans WITHOUT those words: `mailbox_contacts ( id uuid primary key, … )`.
    # That is a whole statement with its prefix simply cut off.
    DOC_SQL_PREFIX = ['', 'select 1 ', 'select 1 from x ', 'explain ', 'create table '].freeze
    def note_doc_sql(element)
      return unless self.class.pg_query?

      text = element.text.to_s
      return if text.strip.empty?

      # A sketch in the shell of a query: non-Latin text outside quotes ("where a
      # row with the same email exists"), dots instead of a value, or a name in
      # angle brackets (`where contact=<email>`). None of the three occurs in
      # SQL — so this is an explanation rather than an example. The angle
      # brackets are here rather than in the general rule: in Ruby and ERB `<`
      # means something else.
      if text.gsub(/'[^']*'/, '').match?(/[\p{Cyrillic}]/) ||
         text.match?(/\.{3}/) || text.match?(/<\w+>/) ||
         # The shorthand a human sketches a table composition with:
         # `media_assets (asset_key pk, sha512, byte_size)` — `pk` instead of
         # `primary key`, with no types. That is an enumeration rather than a
         # statement.
         text.match?(/\bpk\b|\bfk\b/i)
        add('doc_code_sketch', 'sql', '', element.line)
        return
      end

      # Another dialect. Backticks around names and engine keywords are valid
      # SQL, just not PostgreSQL's, and "did not parse" about it speaks of the
      # block's label rather than of the example. We keep a plan for another
      # engine written that way, and three of its blocks were listed as broken.
      # There are several signs of a dialect, and backticks may be absent
      # entirely: for that engine they are `ARRAY JOIN`, `arrayMap`, `FINAL`,
      # tuple element access through dot-number, and an interval without quotes.
      if text.match?(/`\w|\bENGINE\s*=|\bMergeTree\b|\bCODEC\s*\(|\bMODIFY\s+COLUMN\b/i) ||
         text.match?(/\bARRAY\s+JOIN\b|\barray(?:Map|Concat|Join)\s*\(|\bFROM\s+[\w.]+\s+FINAL\b/i) ||
         text.match?(/\bINTERVAL\s+\d+\s+(?:HOUR|DAY|MINUTE|SECOND|WEEK|MONTH)\b/i) ||
         text.match?(/\b\w+\.\d\b/)
        add('doc_code_dialect', 'не postgres', '', element.line)
        return
      end

      # A listing of CONDITIONS rather than a statement: that is how plans write
      # out what the filtering goes by (`member_contacts.status IN
      # VERIFIED_EMAILS`), and with names from the code rather than values. The
      # sign: two lines or more, each holding a comparison, and none holding a
      # keyword that starts a query.
      lines = text.lines.map(&:strip).reject(&:empty?)
      if lines.size >= 2 && lines.none? { |row| row.match?(SQL_START) } &&
         lines.all? { |row| row.match?(/[=<>]|\bIN\b|\bLIKE\b|\bIS\b/i) }
        add('doc_code_sketch', 'sql', '', element.line)
        return
      end

      # Interpolations in examples are the same as in code: `#{…}` and `:name`.
      # The second is the usual form of a query template in our plans
      # (`values (:uuid7, :user_id)`), and without substitution such an example
      # would be listed as broken. A double colon is left alone: that is a cast.
      prepared = text.gsub(/\#\{[^}]*\}/, SQL_HOLE)
                     .gsub(/(?<![:\w]):[a-z_][a-z0-9_]*/i, SQL_HOLE)
                     .gsub(QUESTION_PLACEHOLDER, SQL_HOLE)
                     # `media_jobs_@TOOL@` — an interpolation into a NAME. It is
                     # replaced with a name marker rather than with a value:
                     # otherwise the parse would invent a table
                     # `media_jobs_x` that does not exist. Names with the marker
                     # are filtered out while the columns of the same query stay
                     # visible.
                     .gsub(/@[A-Z_][A-Z0-9_]*@/, IDENT_HOLE)
      parsed = nil
      fragment = false
      DOC_SQL_PREFIX.each_with_index do |prefix, index|
        parsed = PgQuery.parse(prefix + prepared)
        fragment = index.positive?
        break
      rescue StandardError
        next
      end

      # A block sometimes holds SEVERAL statements, and each needs the prefix:
      # in plans table compositions are written one after another, separated by
      # semicolons and without the words `create table`. As a whole such a block
      # will never parse, while one statement at a time parses entirely.
      if parsed.nil?
        pieces = prepared.split(/;\s*\n/).map(&:strip).reject(&:empty?)
        if pieces.size > 1
          parsed_pieces = pieces.map { |piece| parse_with_prefix(piece) }
          if parsed_pieces.all?
            fragment = true
            parsed_pieces.each { |piece| note_doc_sql_names(piece, element.line) }
            add('doc_code_fragment', 'sql', '', element.line)
            return
          end
        end
        add('doc_code_broken', last_sql_error(prepared), 'sql', element.line)
        return
      end

      add('doc_code_fragment', 'sql', '', element.line) if fragment
      note_doc_sql_names(parsed, element.line)
    rescue StandardError
      nil
    end

    # The prefix a fragment is completed into a statement with. Returns a parse
    # or nil — none of them fitted.
    def parse_with_prefix(text)
      DOC_SQL_PREFIX.each do |prefix|
        return PgQuery.parse(prefix + text)
      rescue StandardError
        next
      end
      nil
    end

    def note_doc_sql_names(parsed, line)
      (parsed.tables.map { |t| unqualify(t) } rescue []).each do |table| # rubocop:disable Style/RescueModifier
        next if table.include?(IDENT_HOLE) || table == 'x'

        add('doc_table', table, '', line)
      end
      column_refs(parsed).each do |_qualifier, column|
        add('doc_column', column, '', line) if known.include?(column)
      end
    end

    def last_sql_error(text)
      PgQuery.parse(text)
      'не разобрано'
    rescue StandardError => e
      e.message.to_s.gsub(/\s+/, ' ')[0, 120]
    end

    # Ruby out of a block: we check that it at least PARSES, and take the
    # constants. A full walk is not needed here and would be a lie: a piece of an
    # example does not live in the tree, and its calls are not calls.
    def note_doc_ruby(element, erb: false)
      text = element.text.to_s
      if patch_block?(text)
        add('doc_code_patch', erb ? 'erb' : 'ruby', '', element.line)
        return
      end

      if erb
        text = Erb.ruby(text)
        # Markup with no tags at all is not a broken example but HTML.
        return if text.strip.empty?
      end

      result = Prism.parse(text)
      unless result.success?
        message = result.errors.first&.message.to_s[0, 120]
        kind = message.match?(EXCERPT_ERROR) || hash_excerpt?(text) ? 'doc_code_excerpt' : 'doc_code_broken'
        add(kind, kind == 'doc_code_excerpt' ? (erb ? 'erb' : 'ruby') : (message.presence || 'не разбирается'),
            kind == 'doc_code_excerpt' ? '' : (erb ? 'erb' : 'ruby'), element.line)
        return
      end

      stack = [result.value]
      while (node = stack.pop)
        if node.is_a?(Prism::ConstantReadNode) ||
           (node.is_a?(Prism::ConstantPathNode) && node.respond_to?(:full_name))
          name = node.is_a?(Prism::ConstantReadNode) ? node.name.to_s : (node.full_name rescue nil) # rubocop:disable Style/RescueModifier
          add('doc_const', name, '', element.line) if name.present? && app_constants.include?(name.split('::').first)
        end
        stack.concat(node.compact_child_nodes)
      end
    rescue StandardError
      nil
    end

    def scan_view
      add('view_name', self.class.view_logical_name(path), '', 1)
      scan_renders
      scan_stimulus_markup
    end

    # The second half of the chain with JavaScript. Without it the parse of the
    # controllers would answer only "what is declared in them", while the main
    # question — "does anything attach them and does an action point at an
    # existing method" — would stay unanswered with `data-controller` in 1,022
    # templates.
    # `markup:` is the parse of HTML attributes, `ruby:` of the same attributes
    # built by code. The second is mandatory: a helper of the application
    # attaches `infinite-scroll` with the line
    # `'data-controller' => 'infinite-scroll'`, and without parsing Ruby that
    # controller was listed as attached by NOBODY. One false finding out of
    # three.
    def scan_stimulus_markup(ruby: false)
      elements = ruby ? Js.ruby_elements(source) : Js.markup_elements(source)
      elements.each do |element|
        case element.kind
        when 'use' then add('stimulus_use', element.name, '', element.line)
        when 'action' then add('stimulus_action', element.name, element.detail.to_s, element.line)
        when 'target' then add('stimulus_target_use', element.name, element.detail.to_s, element.line)
        when 'value' then add('stimulus_value_use', element.name, '', element.line)
        when 'dynamic'
          # The name is assembled at runtime — that is a blind spot, and
          # recording it as a link would mean inventing the link.
          add('stimulus_dynamic', element.name, element.detail.to_s, element.line)
        end
      end
    rescue StandardError => e
      add('scan_error', e.class.name, '', 1, detail: { message: e.message[0, 300] })
    end

    def scan_renders
      source.each_line.with_index(1) do |raw, line|
        text = strip_comments(raw)
        offset = 0
        while (found = RENDER_WORD.match(text, offset))
          offset = found.end(0)
          next unless call_position?(text[0...found.begin(0)])

          handle_render(text[offset..].to_s, line, text)
        end
      end
    end

    # An ERB comment and a Ruby comment: the word `render` occurs in them often
    # while there is no call behind it.
    def strip_comments(text)
      text = text.gsub(/<%#.*?(?:%>|\z)/, '')
      text = text.sub(/#\s.*\z/, '') if ruby_parseable?
      text
    end

    # An odd number of quotes to the left means we are inside a string:
    # `include('render js:')` and `it 'does not render …'` are not calls.
    def call_position?(prefix)
      return false if prefix.count("'").odd? || prefix.count('"').odd?

      prefix.match?(CALL_PREFIX)
    end

    def handle_render(rest, line, whole_line)
      return unless rest.match?(/\A[\s(]/)

      # A call does not stretch past the end of an ERB tag, and a line sometimes
      # holds several of them.
      rest = rest.split('%>').first.to_s.sub(/\A\s*\(/, '').lstrip
      render_arguments(rest).each { |argument| handle_render_argument(argument, line, whole_line) }
    end

    # What exactly gets rendered. `render json:`/`render plain:` render no view
    # — they have no business in the graph, while previously they made up most of
    # the "blind spots".
    def render_arguments(rest)
      found = []
      # The bare form `render 'x/y'` is a view; a call with a foreign key
      # (`render json:`) is not. A bare argument and keys do not exclude each
      # other: `render 'account/login', :layout => layout` names both.
      found << rest unless ANY_KEY.match?(rest)
      offset = 0
      while (key = VIEW_KEY.match(rest, offset))
        found << rest[key.end(0)..]
        offset = key.end(0)
      end
      found
    end

    # `render partial: cond ? 'a' : 'b'` — both branches are named in full, and
    # both are real. There is no need to parse the whole expression: the literals
    # suffice.
    TERNARY = /\A[^,]*?\?\s*(['"])([^'"]*)\1\s*:\s*(['"])([^'"]*)\3/

    def handle_render_argument(argument, line, whole_line)
      if argument.start_with?("'", '"')
        add_render_string(argument, line, whole_line)
      elsif (pair = TERNARY.match(argument))
        [pair[2], pair[4]].each { |branch| add_static_render(branch, line) }
      else
        expression = read_expression(argument)
        return if expression.nil? || NOT_A_TARGET.include?(expression)

        # A contour helper with a LITERAL: `censors_partial_path('show_next')`.
        # The template name here is assembled by the helper (contour,
        # controller, name), and as a whole it is indeed unknown — but the last
        # segment is named directly, and candidates are findable through it.
        # There are 76 such renders out of 258 "blind" ones, that is, almost a
        # third of this layer's blindness was blindness over nothing.
        if (built = PATH_HELPER.match(expression))
          add('render_dynamic', "*#{built[2]}", 'skeleton', line,
              detail: { glob: like_pattern("*#{built[2]}"), source: snippet(whole_line),
                        expr: expression[0, 100], helper: built[1], scope: scope_name })
          return
        end

        # The name sits entirely in a variable — there is no pattern and there
        # will be no candidates. But there is the name of the variable: the index
        # now records the assignments to it, and the blind spot stops being a
        # dead end.
        @wanted_roots << hole_root(expression)
        add('render_dynamic', expression[0, 100], '', line,
            detail: { source: snippet(whole_line), root: hole_root(expression), scope: scope_name })
      end
    end

    # A helper that assembles a template path, with a literal last segment. The
    # list of endings is closed: in all 76 places found it is `_partial_path` or
    # `_template_path`, and taking any `_path(` is not allowed — a route helper
    # with a literal (`user_path('x')`) is not a template. A segment shorter than
    # four characters is not taken either: by `%list` every other template
    # becomes a candidate, and the hint turns into noise.
    PATH_HELPER = /\A([a-z_]+_(?:partial|template)_path)\(\s*['"]([a-z0-9_]{4,})['"]\s*\)\z/

    def add_render_string(rest, line, whole_line)
      body, interpolated, holes = read_string(rest)
      return if body.nil?

      target = body.sub(%r{\A/}, '')
      unless interpolated
        add_static_render(target, line)
        return
      end

      holes.each { |hole| @wanted_roots << hole_root(hole) }
      skeleton = target.squeeze('*')
      # There is no literal part at all (`"#{a}/#{b}"`) — the pattern is empty,
      # and through it every view becomes a candidate. That is a blind spot
      # rather than a hint.
      unless skeleton.delete('*').match?(/[a-z0-9]{3}/i)
        add('render_dynamic', skeleton, '', line,
            detail: { source: snippet(whole_line), expr: holes.join(' + '),
                      root: hole_root(holes.first), scope: scope_name })
        return
      end

      add('render_dynamic', skeleton, 'skeleton', line,
          detail: { glob: like_pattern(skeleton), source: snippet(whole_line),
                    expr: holes.join(' + '), root: hole_root(holes.first), scope: scope_name })
    end

    def add_static_render(target, line)
      target = target.sub(%r{\A/}, '')
      add('render_ref', target, '', line) if target.match?(STATIC_TARGET)
    end

    # A pattern for LIKE. Escaped with a tilde rather than a backslash: view
    # names are full of underscores, and for LIKE an underscore is a wildcard.
    def like_pattern(skeleton)
      skeleton.gsub(/[~%_]/) { |char| "~#{char}" }.tr('*', '%')
    end

    def snippet(text)
      text.strip[0, 160]
    end

    # Reads a string literal from the start of `rest`. Every hole `#{...}`
    # becomes an asterisk while its expression stays in the third value: the
    # assignments are later looked up by it. => [text, was_interpolated,
    # expressions]; nil if the string is not closed.
    def read_string(rest)
      quote = rest[0]
      out = +''
      interpolated = false
      holes = []
      index = 1
      while index < rest.length
        char = rest[index]
        if char == '\\'
          out << rest[index + 1].to_s
          index += 2
          next
        end
        break if char == quote

        if quote == '"' && char == '#' && rest[index + 1] == '{'
          interpolated = true
          stop = skip_interpolation(rest, index + 2)
          holes << rest[(index + 2)...(stop - 1)].to_s.strip
          index = stop
          out << '*'
          next
        end
        out << char
        index += 1
      end
      return [nil, false, []] if index >= rest.length

      [out, interpolated, holes]
    end

    # The end of `#{...}`: the braces are counted and the strings inside skipped.
    def skip_interpolation(rest, index)
      depth = 1
      while index < rest.length
        case rest[index]
        when '{' then depth += 1
        when '}'
          depth -= 1
          return index + 1 if depth.zero?
        when "'", '"'
          quote = rest[index]
          index += 1
          index += 1 while index < rest.length && rest[index] != quote
        end
        index += 1
      end
      index
    end

    # `acts['partial']`, `bootstrap_partial_path('x')`, `@partial` — the name
    # together with its balanced tail, but without its neighbours on the line:
    # `layout and return` has to be cut down to `layout`.
    def read_expression(rest)
      head = EXPR_HEAD.match(rest)
      return nil if head.nil?

      out = head[0]
      tail = rest[head.end(0)..].to_s
      while (open = tail[0]) && '(['.include?(open)
        stop = balanced_end(tail)
        break if stop.nil?

        out += tail[0...stop]
        tail = tail[stop..]
      end
      out
    end

    def balanced_end(text)
      pairs = { '(' => ')', '[' => ']' }
      depth = 0
      index = 0
      while index < text.length
        char = text[index]
        if pairs.key?(char)
          depth += 1
        elsif pairs.value?(char)
          depth -= 1
          return index + 1 if depth.zero?
        elsif char == "'" || char == '"'
          index += 1
          index += 1 while index < text.length && text[index] != char
        end
        index += 1
      end
      nil
    end

    # --- sql ----------------------------------------------------------------

    def scan_bare_sql
      analyze_sql(source, 1)
    end

    # When the parse failed, the table name is still extracted with a regular
    # expression — but as a separate kind: that is a guess rather than parsed
    # SQL.
    TABLE_GUESS = /\b(?:from|into|update|join)\s+(?:only\s+)?([a-z_][a-z0-9_]*)/i

    # After `from`/`update` stands more than just a table name: `update x set
    # …`, `from generate_series(…)`, `from (select …) cohort`. The guess is
    # marked as a guess anyway, but there is no point letting the word `set` into
    # the index.

    # blind: a hole from #{...} glued to an identifier. Parsing that is not
    # allowed: PostgreSQL considers `auth_sid$1` a legitimate name (`$` is
    # allowed in identifiers), and the index would fill up with tables that do
    # not exist.
    def analyze_sql(sql, line, blind: false, holes: nil)
      # A query is assembled in the body of this method: the mark will go into
      # the `def` record, and the hole `#{where_sql}` will know that what it
      # substitutes is SQL rather than a value.
      @sql_here = true
      table_roots = []
      if holes.present?
        table_roots = record_holes(sql, holes, line, blind: blind)
                      .select { |context, root| context == 'table' && !root.empty? }
                      .map(&:last).uniq
      end
      sql = sql.gsub(QUESTION_PLACEHOLDER, SQL_HOLE)
      # `'select … where sex=#{sex}'` in SINGLE quotes is not Ruby interpolation
      # but text, and it used to reach the parse as it is: the parser does not
      # know `#{`, and the query went into the blind spots entirely. For the
      # parse it is the same kind of hole.
      sql = sql.gsub(/\#\{[^}]*\}/, SQL_HOLE)
      return unparsed(sql, line, 'парсер pg_query недоступен') unless self.class.pg_query?

      # The parse goes in two attempts, and the second exists for 256 queries out
      # of 731 that went into the blind spots entirely because of ONE
      # interpolation.
      #
      # First attempt: `#{...}` → `$1`, that is, a parameter. In a value position
      # that is correct, while in a NAME position a parameter is not legitimate,
      # and `select * from $1` does not parse at all — together with everything
      # in it: columns, write targets, joins. The second attempt substitutes a
      # NAME (`xrefhole`): the query parses, and everything except the name
      # itself becomes visible.
      #
      # The marker name has to be recognisable: `auth_sid$1` turns into
      # `auth_sidxrefhole`, and such a table must not be let into the index — it
      # does not exist. Everything containing the marker is filtered out and goes
      # into a guess by the literal part, as before.
      note_swallowed_comment(sql, line)

      @hole_table = false
      parsed = nil
      hole_names = false
      begin
        parsed = PgQuery.parse(sql) unless blind
      rescue StandardError
        parsed = nil
      end
      if parsed.nil?
        hole_names = true
        parsed, failure = parse_with_holes(sql)
        return unparsed(sql, line, blind ? 'имя собрано интерполяцией' : failure) if parsed.nil?
      end

      aliases = parsed.respond_to?(:aliases) ? parsed.aliases : {}
      tables = parsed.tables.map { |t| unqualify(t) }

      if hole_names
        # The table name is assembled at runtime. Whatever is left of it in
        # letters is a guess (`auth_sid$1` → `auth_sid`), and whatever is left
        # of nothing is an honest blind spot — but now ONLY about the name rather
        # than about the whole query.
        named, built = tables.partition { |t| !t.include?(IDENT_HOLE) }
        named.each { |t| add('pg_table', t, '', line) }
        # The name of one of the tables is assembled at runtime and is NOT
        # VISIBLE in the list. That means "the only table of the query" is a lie:
        # an unqualified column must not be bound to the remaining one. Without
        # this rule `select … from top_gallery#{x} … and user_id not in (select …
        # from member_types …)` gave all the columns of the first table to the
        # second: six false "columns that do not exist".
        @hole_table = true if built.any?
        built.each do |t|
          stem = t.gsub(IDENT_HOLE, '')
          if stem.length >= 3 && !@guess_stoplist.include?(stem)
            add('pg_table_guess', stem, '', line)
          else
            add('sql_blind', sql.to_s.gsub(/\s+/, ' ').strip[0, 120], '', line,
                detail: { error: 'имя таблицы собрано интерполяцией целиком',
                          root: table_roots.first })
          end
        end
        tables = named
      else
        tables.each { |t| add('pg_table', t, '', line) }
      end

      derived = derived_table?(parsed)
      # Names that are NOT table columns: aliases of computations (explicit and
      # implicit) and aliases of functions in `from`.
      computed = computed_aliases(parsed) | function_aliases(parsed)
      column_refs(parsed).each do |qualifier, column|
        next if column.include?(IDENT_HOLE)

        owner =
          if qualifier.nil?
            # With a subquery in `from` the only table of the query is NOT the
            # owner of an unqualified column: the name may belong to the output
            # of the subquery. The same with AN ALIAS OF A COMPUTATION: in
            # `select abs(a-b) as abs … order by abs` the word `abs` is the name
            # of an output column rather than a column of a table. And the same
            # if one of the table names is assembled at runtime: the remaining
            # table is "the only one" only in appearance.
            tables.size == 1 && !derived && !@hole_table && !computed.include?(column) ? tables.first : ''
          else
            unqualify(aliases[qualifier] || qualifier)
          end
        add('pg_column', column, owner, line)
      end

      # Columns whose value takes part in a condition or an ordering: strong
      # evidence of use, unlike an enumeration in the output list.
      filter_columns(parsed).each do |qualifier, column|
        next if column.to_s.include?(IDENT_HOLE)

        owner =
          if qualifier.nil?
            tables.size == 1 && !derived && !@hole_table ? tables.first : ''
          else
            unqualify(aliases[qualifier] || qualifier)
          end
        add('pg_column_filter', column, owner, line)
      end

      # Columns that are WRITTEN to. The sets do not intersect by construction:
      # the target of an `update set` and the column list of an `insert` are a
      # ResTarget with a name rather than a ColumnRef, so they do not land among
      # the reads. `update t set b = b + 1` honestly yields both a write of `b`
      # and a read of `b`.
      #
      # The owner is taken from the DML table rather than from the only table of
      # the query: in `insert into t (x) select y from u` there are two tables but
      # the write goes to one.
      dml = (parsed.dml_tables.map { |t| unqualify(t) } rescue []) # rubocop:disable Style/RescueModifier
      # A `CREATE RULE` has no DML table: it is DDL. But a rule does have a write
      # target — the table it is attached to — otherwise the records go without an
      # owner.
      dml = [rule_target(parsed)].compact if dml.empty?
      target = dml.size == 1 ? dml.first : ''
      write_targets(parsed).reject { |column| column.to_s.include?(IDENT_HOLE) }
        .each { |column| add('pg_column_write', column, target, line) }

      # `select *` is the whole row, and further down values are taken out of it
      # by a string key. A separate record: without it "this column is not read"
      # is false for any table ever selected with a star. For a qualified star the
      # owner is known even with several tables: `select u.* from users u, dm d`.
      stars = 0
      star_refs(parsed).each do |qualifier|
        next if qualifier.to_s.include?(IDENT_HOLE)

        owner = if qualifier.nil?
                  tables.size == 1 ? tables.first.to_s : ''
                else
                  unqualify(aliases[qualifier] || qualifier)
                end
        stars += 1
        add('pg_select_star', '*', owner, line)
      end

      # What is named in this line of the file: from here a read by key learns
      # its table. If one line holds two queries there will be two tables, and the
      # read will have no owner: better with no owner than with somebody else's.
      place = (@sql_at_line[line] ||= { tables: [], star: false })
      place[:tables] |= tables
      place[:star] ||= stars.positive?

      record_lineage(parsed, line)

      json_keys(parsed).each do |base, key|
        # A key assembled by interpolation (`"telegram->>'#{a}_#{b}'"`) is not a
        # name but a pattern: there is no point in it reaching the report about
        # keys that were not found.
        next if key.include?(SQL_HOLE)

        # The owner is always "table.column", with a question mark for the
        # unknown part. Otherwise, with an undetermined table, the column took
        # its place.
        table = tables.size == 1 ? tables.first : '?'
        add('json_key', key, "#{table}.#{base.to_s.empty? ? '?' : base}", line)
      end
    rescue StandardError => e
      unparsed(sql, line, e.message)
    end

    # --- holes in a query ---------------------------------------------------

    # What stands in a hole and in which position of the query that hole sits.
    #
    # The parser substitutes `$1` for `#{...}` — otherwise the SQL will not parse
    # at all. But the expression itself used to be thrown away, and the question
    # "where in an `in (…)` is a variable substituted that had text with a select
    # assigned to it" had to be walked by hand across the whole tree. Now a hole
    # is as much a record of the index as a table or a column: the root of the
    # expression in token, the position in the query in owner, the expression
    # itself in detail.
    # Returns [[context, root], …] — what was actually recorded. Needed by the
    # caller: a table name assembled in full, otherwise the hole has to be looked
    # up BY LINE NUMBER, and in a heredoc the blind record sits on the line where
    # the query starts while the hole sits on the line of the interpolation
    # itself. They never coincide, and of 166 such places not one was resolved.
    def record_holes(sql, holes, line, blind:, carrier: nil, fragment: false)
      whole = sql.gsub(/\s+/, ' ').strip[0, 200]
      marked = fragment && sql.match?(SQL_PART_MARK)
      recorded = []
      holes.each do |hole|
        expr = hole[:expr].to_s
        next if expr.empty?

        context = hole_context(sql, hole[:offset])
        if fragment
          next unless FRAGMENT_CONTEXTS.include?(context)
          next if !marked && !FRAGMENT_SELF_EVIDENT.include?(context)
        end

        root = hole_root(expr)
        hole_line = hole[:line] || line
        # The same hole twice (a fragment is parsed both on its own and as the
        # value of an assignment) — one row rather than two occurrences.
        next unless @recorded_holes.add?([hole_line, hole[:offset], root])

        @wanted_roots << root unless root.empty?
        recorded << [context, root]
        add('sql_hole', root.empty? ? expr[0, 60] : root, context, hole_line,
            detail: { expr: expr[0, 200], scope: scope_name, blind: blind, sql: whole,
                      carrier: carrier, fragment: fragment,
                      call: expr_call(expr), const: (root if root.match?(/\A[A-Z]/)) })
      end
      recorded
    end

    # `ReportSql.new.take_all` — the carrier is not the class but its method.
    # The root of the expression here is a constant, and the method name cannot
    # be found by it: what has to be searched for is `take_all`. For
    # `ids.map(&:to_i).join(',')` the root is lower-case — there the last call is
    # `join`, and there is nothing to search for by it.
    def expr_call(expr)
      head = expr.to_s[/\A[A-Za-z_][\w:]*(?:\s*\.\s*[a-z_]\w*[!?]?)+/]
      return nil if head.nil? || !head.match?(/\A[A-Z]/)

      parts = head.split('.').map(&:strip)
      parts.pop if parts.size > 2 && parts.last == 'new'
      parts.last == 'new' ? nil : parts.last
    end

    # The root of an expression: the name it can be searched for at all.
    # `ids.map(&:to_i).join(',')` -> `ids`, `params[:sort]` -> `params`.
    HOLE_ROOT = /\A[@$]{0,2}[A-Za-z_][A-Za-z0-9_]*[!?]?/

    def hole_root(expr)
      HOLE_ROOT.match(expr.to_s)&.to_s.to_s
    end

    # The position of a hole in a query. That is the difference between "a value
    # was substituted" and "a piece of a query was substituted": `in (…)`,
    # `order by …` and a name glued to an identifier behave nothing like
    # `where id = …`.
    #
    # The order of the checks matters: `where id in (` is in_list rather than
    # condition; `from ` is table, while `from big_users_` is glue.
    def hole_context(sql, offset)
      left = sql[0, offset].to_s
      return 'quoted' if inside_string_literal?(left)

      # `create table t ($1)` — in the position of the hole stands a list of
      # column DEFINITIONS, and for the query to parse what must be substituted
      # is `name type` rather than a value.
      return 'ddl_columns' if left.match?(/\bcreate\s+(?:temp\s+|temporary\s+|unlogged\s+)?table\b[^(]*\(\s*\z/i)

      # The hole stands in the position of A COLUMN NAME: `"#{make_goal(g)} in
      # (1,2)"`. A decisive case for the question "which fields we do not use in
      # the code": the name is assembled at runtime, it does not exist in the
      # tree as a word, and eleven columns of a series looked unused. The sign: a
      # hole at the start (or right after a parenthesis, `and`, a comma) with a
      # comparison operator to its right.
      right = sql[(offset + SQL_HOLE.length)..].to_s
      if left.match?(/(?:\A|[(,]\s*|\b(?:and|or|where|on|having|select|set)\s+)\z/i) &&
         right.match?(/\A\s*(?:not\s+)?(?:in\s*\(|=|<|>|<=|>=|<>|!=|like\b|ilike\b|is\b|between\b)/i)
        return 'column'
      end

      case left.gsub(/\s+/, ' ')
      # Any position inside an unclosed `in (…)` rather than only right after
      # the parenthesis: in `in ($1, $1)` the second hole is the same as the
      # first. But if a select has started inside the parenthesis we are already
      # in a subquery, and the position there is different.
      when /\bin\s*\((?![^)]*\bselect\b)[^)(]*\z/i                then 'in_list'
      when /\b(?:from|join|into|update|table)\s+(?:only\s+)?\z/i then 'table'
      when /\border by [\w.,() ]*\z/i                            then 'order_by'
      when /\bgroup by [\w.,() ]*\z/i                            then 'group_by'
      when /\b(?:limit|offset)\s+\z/i                            then 'limit'
      when /\bvalues\s*(?:\([^)]*)?\z/i                          then 'values'
      when /(?:=|<|>|<=|>=|<>|!=|\blike|\bilike)\s*\z/i          then 'value'
      when /\bset\s+[\w.,'"= ]*\z/i                              then 'set'
      when /\b(?:where|and|or|on|having)\s+\z/i                  then 'condition'
      when /[A-Za-z0-9_$]\z/                                     then 'glue'
      # We are INSIDE a condition even if something else stands between `where`
      # and the hole: `where id = 1 and $1`, `where $1 $1 limit 10`. The sign is
      # the last `where` with no `select` after it. Without this rule a second
      # hole in a row got the position `select_list`, that is, a direct untruth:
      # 327 holes counted as "in the output list" while standing in a condition.
      when /\bwhere\b(?:(?!\bselect\b).)*\z/mi                   then 'condition'
      when /\bselect\b/i                                         then 'select_list'
      else 'other'
      end
    end

    JSON_OPERATORS = %w[-> ->> #> #>>].freeze

    # `meta->>'status'` — a key inside jsonb. jsonb has no schema, and such
    # places are the only static trace of what lies in the column.
    # The owner is written as `table.column` rather than as the table: the key
    # belongs to the column.
    def json_keys(parsed)
      out = []
      parsed.walk! do |*nodes|
        nodes.each do |node|
          next unless node.is_a?(PgQuery::A_Expr)

          operator = node.name.map { |part| part.respond_to?(:string) && part.string ? part.string.sval : nil }
                         .compact.join
          next unless JSON_OPERATORS.include?(operator)

          value = node.rexpr&.a_const&.sval&.sval
          next if value.nil? || value.empty?

          keys = operator.start_with?('#') ? value.delete('{}').split(',') : [value]
          base = base_column(node.lexpr)
          keys.each do |key|
            key = key.strip
            out << [base.to_s, key] unless key.empty?
          end
        end
      end
      out.uniq
    end

    # We descend the chain `payload->'a'->>'b'` down to the column name.
    def base_column(node)
      node = node.a_expr.lexpr while node.respond_to?(:a_expr) && node.a_expr

      fields = node.respond_to?(:column_ref) && node.column_ref ? node.column_ref.fields : nil
      return nil if fields.nil? || fields.empty?

      fields.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }.last
    end

    # The SQL could not be parsed: the place is marked as a blind spot and the
    # table name extracted with a regular expression — as a separate kind,
    # because that is a guess.
    # Not every unparsed string is a blind spot. A blind spot is "there is a
    # query here and we do not know which"; and there are two other cases which
    # inflated the blind-spot count and thereby lied about our own ignorance:
    #
    #   A FRAGMENT — the string breaks off mid-word
    #     (`insert into queue_inbox1`): the query is assembled from pieces, or
    #     it is an expectation in a spec. There is nothing to be ignorant about:
    #     there is no whole statement in that string.
    #   PROSE — a human phrase that happens to start with a keyword
    #     (`UPDATE friends_only not found`). That is a message rather than a
    #     query.
    #
    # Both are written with the kind `sql_piece`: the record remains (and so do
    # the guesses about names), but it does not enter the blind-spot count.
    PROSE_LETTERS = /[^\p{ASCII}]/
    # The sign that this is a query after all rather than a phrase: there is a
    # `from`/`where`/`set`/`values`/`join`, or at least a parenthesis, a comma, a
    # comparison.
    SQL_STRUCTURE = /\b(?:from|where|set|values|join|into|table)\b|[(),=<>*]/i
    def unparsed(sql, line, reason)
      text = sql.to_s.gsub(/\s+/, ' ').strip
      bare = text.gsub(/'[^']*'/, '').gsub(/"[^"]*"/, '')
      kind = if reason.to_s.include?('end of input')
               'sql_piece'
             elsif (@prose_is_non_ascii && bare.match?(PROSE_LETTERS)) || !bare.match?(SQL_STRUCTURE)
               # "Select a valid review status" starts with a keyword and is no
               # query: no `from`, no parentheses, no comma, no comparison. That
               # is a button caption rather than SQL.
               'sql_piece'
             else
               'sql_blind'
             end
      add(kind, text[0, 120], '', line, detail: { error: reason.to_s[0, 200] })
      sql.to_s.scan(TABLE_GUESS).flatten.map(&:downcase).uniq.each do |guess|
        add('pg_table_guess', guess, '', line) unless @guess_stoplist.include?(guess)
      end
      nil
    end

    # `.squish` glued the query into one line, and there was a `--` comment in
    # it: everything after the comment ceased to exist for the database. That is
    # not theory — a condition has already been lost that way in this tree, and
    # because of it the report called 961 methods dead instead of 643.
    #
    # The sign: `--` outside quotes with SQL to its right on the same line.
    COMMENT_EATS = /\b(?:select|from|where|and|or|order\s+by|group\s+by|limit|values|set|join)\b/i
    def note_swallowed_comment(sql, line)
      return unless sql.include?('--') && !sql.include?("\n")

      position = 0
      while (found = sql.index('--', position))
        tail = sql[(found + 2)..].to_s
        if !inside_string_literal?(sql[0, found]) && tail.match?(COMMENT_EATS)
          add('sql_comment_eats', sql.gsub(/\s+/, ' ').strip[0, 120], '', line,
              detail: { dead: tail.strip[0, 80] })
          return
        end
        position = found + 2
      end
    end

    # What to replace a hole with so that the query becomes parseable depends on
    # THE POSITION of the hole. One substitution will not do: in
    # `where $1 $1 limit $1` the first two need a truth value and the third a
    # number, while `update t set $1` requires an assignment.
    PARSE_TOKENS = {
      'table' => IDENT_HOLE, 'column' => IDENT_HOLE, 'glue' => IDENT_HOLE,
      'set' => "#{IDENT_HOLE}=1", 'ddl_columns' => "#{IDENT_HOLE} integer",
      'limit' => '1', 'value' => '1', 'in_list' => '1', 'values' => '1',
      'order_by' => '1', 'group_by' => '1', 'select_list' => '1',
      'quoted' => 'x', 'condition' => 'true', 'other' => 'true'
    }.freeze

    # The second and third parsing attempts: first with a single name, then with
    # a substitution BY POSITION. The third is needed where one name is not
    # enough — in a condition a name is not legitimate, and in a `limit` it is
    # not legitimate either.
    # => [parsed, the reason for the refusal]
    def parse_with_holes(sql)
      [sql.gsub(SQL_HOLE, IDENT_HOLE), render_by_context(sql)].uniq.each do |candidate|
        return [PgQuery.parse(candidate), nil]
      rescue StandardError => e
        @last_parse_error = e.message
      end
      [nil, @last_parse_error]
    end

    def render_by_context(sql)
      out = sql.dup
      offsets = []
      position = 0
      while (found = out.index(SQL_HOLE, position))
        offsets << found
        position = found + SQL_HOLE.length
      end
      # From the end: a substitution changes the length, and all the offsets to
      # the left of it stay correct.
      offsets.reverse_each do |offset|
        context = hole_context(out, offset)
        token = PARSE_TOKENS[context] || 'true'
        # The hole stands AFTER a complete condition: `where member_type in ($1)
        # $1`. A truth value on its own is not legitimate there — a connective is
        # needed, otherwise the query will not parse and everything in it stays
        # invisible.
        left = out[0, offset].to_s.rstrip
        token = "and #{token}" if context == 'condition' && left.match?(/[)\w'"]\z/) &&
                                  !left.match?(/\b(?:where|and|or|having|on|not)\z/i)
        out[offset, SQL_HOLE.length] = token
      end
      # Two unknown parts of a condition in a row yield `true true` — that is
      # the same single unknown part.
      out.gsub(/\btrue(\s+true\b)+/, 'true')
    end

    # There is one schema in the index (public), so `public.big_users` and
    # `big_users` are the same name.
    def unqualify(name)
      name.to_s.sub(/\Apublic\./, '')
    end

    # Write targets: `update … set a = …` and the column list of an
    # `insert into t (a, b)`. These are different answers to "the column is
    # used": in one table 17 columns out of 71 turned out to be written to and
    # read by nobody.
    # The actions a query actually performs. For an ordinary query that is itself,
    # while for `CREATE RULE … DO INSTEAD UPDATE …` these are the nested actions
    # of the rule: without them the write targets and the value lineage inside a
    # rule are invisible, and a rule is precisely a rewrite that changes the
    # meaning of an insert.
    def effective_statements(parsed)
      parsed.tree.stmts.flat_map do |wrapper|
        stmt = wrapper.stmt
        next [stmt] unless stmt.node == :rule_stmt

        Array(stmt.rule_stmt.actions).map { |action| action }
      end
    end

    # The table a rule is attached to.
    def rule_target(parsed)
      wrapper = parsed.tree.stmts.find { |item| item.stmt.node == :rule_stmt }
      return nil if wrapper.nil?

      name = unqualify(wrapper.stmt.rule_stmt.relation&.relname.to_s)
      name.presence
    rescue StandardError
      nil
    end

    def write_targets(parsed)
      out = []
      effective_statements(parsed).each do |stmt|
        list =
          case stmt.node
          when :update_stmt then stmt.update_stmt.target_list
          when :insert_stmt then stmt.insert_stmt.cols
          end
        next if list.nil?

        out.concat(list.filter_map { |item| item.res_target&.name.presence })
      end
      out.uniq
    rescue StandardError
      []
    end

    # The lineage of a column's value: `insert into t (a) select x from u` means
    # `t.a` is taken from `u.x`, and `update t set a = s.x from s` means the same.
    # It answers a question that cannot be asked otherwise: where does what lies
    # in this column come from at all. The matching is positional — exactly as
    # the database itself does it.
    def record_lineage(parsed, line)
      effective_statements(parsed).each do |stmt|
        case stmt.node
        when :insert_stmt
          insert = stmt.insert_stmt
          target = unqualify(insert.relation&.relname.to_s)
          select = insert.select_stmt&.select_stmt
          next if target.empty? || select.nil? || insert.cols.empty?

          sources = source_columns(select)
          insert.cols.each_with_index do |col, index|
            name = col.res_target&.name.presence
            next if name.nil? || sources[index].nil?

            add('col_lineage', "#{target}.#{name}", sources[index], line, detail: { via: 'insert-select' })
          end
        when :update_stmt
          update = stmt.update_stmt
          target = unqualify(update.relation&.relname.to_s)
          next if target.empty?

          # The aliases come from `from`: `update t set a = p.key from photos p`
          # must yield `photos.key` rather than `p.key`.
          aliases = (update.from_clause.to_h do |item|
            [item.range_var&.alias&.aliasname.to_s, unqualify(item.range_var&.relname.to_s)]
          end rescue {}) # rubocop:disable Style/RescueModifier

          update.target_list.each do |item|
            name = item.res_target&.name.presence
            from = column_name_of(item.res_target&.val, aliases)
            next if name.nil? || from.nil?

            add('col_lineage', "#{target}.#{name}", from, line, detail: { via: 'update-from' })
          end
        end
      end
    rescue StandardError
      nil
    end

    # The columns of a selection list in order: `table.column`, or nil if the
    # position holds a computation rather than a column.
    #
    # Lineage is recorded ONLY for a genuine source column. Writing "an
    # expression" is tempting, but then every `update t set a = 1` yields a
    # record and the useful links drown: the absence of a source already reads as
    # "computed in place".
    def source_columns(select)
      tables = (select.from_clause.map { |item| unqualify(item.range_var&.relname.to_s) }.reject(&:empty?) rescue []) # rubocop:disable Style/RescueModifier
      aliases = (select.from_clause.to_h do |item|
        [item.range_var&.alias&.aliasname.to_s, unqualify(item.range_var&.relname.to_s)]
      end rescue {}) # rubocop:disable Style/RescueModifier

      select.target_list.map do |item|
        value = item.res_target&.val
        parts = value&.column_ref&.fields&.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }
        next nil if parts.blank?

        if parts.size >= 2
          "#{aliases[parts[-2]].presence || parts[-2]}.#{parts[-1]}"
        else
          "#{tables.size == 1 ? tables.first : '?'}.#{parts[-1]}"
        end
      end
    end

    def column_name_of(value, aliases = {})
      parts = value&.column_ref&.fields&.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }
      return nil if parts.blank?
      return "?.#{parts[-1]}" if parts.size < 2

      "#{aliases[parts[-2]].presence || parts[-2]}.#{parts[-1]}"
    end

    # The stars of a query, each with its own qualifier: `ue.*` is a star on
    # `ue` and NOT a column named `ue`. Previously it was the latter: such a
    # reference has exactly one string field, and it travelled into the columns,
    # and from there into the report "the code reads a column the table does not
    # have". A check on one table found exactly such a record: `select ue.*`
    # yielded `member_events.ue`.
    def star_refs(parsed)
      out = []
      parsed.walk! do |*nodes|
        nodes.flatten.each do |node|
          next unless node.is_a?(PgQuery::ColumnRef)
          next unless node.fields.any? { |field| field.node == :a_star }

          parts = node.fields.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }
          out << parts.last
        end
      end
      out.uniq
    rescue StandardError
      []
    end

    # Aliases of COMPUTATIONS in the output list: `abs(a - b) as abs`,
    # `count(*) as count`. Such a name in an `order by`/`group by` refers to the
    # output of the query rather than to a column of a table, and binding it to a
    # table invented a column. An alias over a plain column (`select x as x`)
    # does not count: the name there is real.
    # ONLY the output list of a select is taken. For `update t set g1 = g1 + 1`
    # the target is also a ResTarget with a name and an expression, and without
    # this restriction the read of `g1` on the right lost its owner. A spec is
    # what caught that.
    def computed_aliases(parsed)
      out = []
      parsed.walk! do |*nodes|
        nodes.flatten.each do |node|
          next unless node.is_a?(PgQuery::SelectStmt)

          node.target_list.each do |item|
            target = item.res_target
            next if target.nil?

            # An output name is sometimes IMPLICIT: `select count(*) … order by
            # count desc` has no alias, and PostgreSQL names the column `count`
            # while the ordering refers to it rather than to a column of a table.
            # Without this the report said "the code reads a column `count` that
            # the table does not have".
            if target.name.to_s.empty?
              out << function_name(target.val) if target.val.respond_to?(:func_call)
              next
            end
            next if target.val.respond_to?(:column_ref) && target.val.column_ref

            out << target.name.to_s
          end
        end
      end
      out.compact.to_set
    rescue StandardError
      Set.new
    end

    # The name of a function in a call — also the implicit name of an output
    # column.
    def function_name(value)
      call = value.func_call
      return nil if call.nil?

      call.funcname.filter_map { |part| part.string&.sval }.last
    rescue StandardError
      nil
    end

    # Aliases of FUNCTIONS in `from`: `from uc, lateral regexp_matches(…) m`
    # yields the name `m`, and `m[1]` in the output list is an access to the
    # output of the function rather than a column of a table. Without this the
    # report said "the code reads a column `m` that `member_comments` does not
    # have".
    def function_aliases(parsed)
      out = []
      parsed.walk! do |*nodes|
        nodes.flatten.each do |node|
          next unless node.is_a?(PgQuery::RangeFunction)

          name = node.alias&.aliasname
          out << name if name.present?
        end
      end
      out.to_set
    rescue StandardError
      Set.new
    end

    # Whether the query holds a derived table — a subquery in `from`. If it does,
    # an unqualified column MUST NOT be bound to the only table: in
    # `select b from (select … as b from media) t` the column `b` belongs to the
    # subquery rather than to `media`, and the binding produced a non-existent
    # column.
    def derived_table?(parsed)
      found = false
      parsed.walk! do |*nodes|
        nodes.flatten.each { |node| found = true if node.is_a?(PgQuery::RangeSubselect) }
      end
      found
    rescue StandardError
      false
    end

    # Columns whose VALUE takes part in the work of the query: a condition, a
    # join, an ordering, a grouping. Strong evidence of use — unlike the output
    # list, where a column is merely enumerated. And they are usually enumerated
    # all at once as a list, so "named in the selection" says nothing at all.
    #
    # The position of a node is taken from THE PATH the walker provides
    # (`[:stmts, 0, :stmt, :select_stmt, :where_clause, …]`): walking the subtree
    # by hand is pointless, the protobuf nodes return their children as hashes
    # and the reference to the node is lost.
    FILTER_PATH = %i[where_clause having_clause sort_clause group_clause quals on_clause].freeze
    def filter_columns(parsed)
      out = []
      parsed.walk! do |_parent, _field, node, path|
        next unless node.is_a?(PgQuery::ColumnRef)
        next unless path.is_a?(Array) && path.any? { |step| FILTER_PATH.include?(step) }

        parts = node.fields.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }
        next if parts.empty?

        out << (parts.size >= 2 ? [parts[-2], parts[-1]] : [nil, parts[-1]])
      end
      out.uniq
    rescue StandardError
      []
    end

    def column_refs(parsed)
      out = []
      parsed.walk! do |*nodes|
        nodes.each do |node|
          next unless node.is_a?(PgQuery::ColumnRef)
          # A star is parsed separately: for `ue.*` there is one string field,
          # and without this filtering it became a column.
          next if node.fields.any? { |field| field.node == :a_star }

          parts = node.fields.filter_map { |f| f.respond_to?(:string) && f.string ? f.string.sval : nil }
          next if parts.empty?

          out << (parts.size >= 2 ? [parts[-2], parts[-1]] : [nil, parts[-1]])
        end
      end
      out.uniq
    end

    # --- names from the database in the text --------------------------------

    # Candidates. One row per file and name: otherwise `id` would yield hundreds
    # of thousands of rows, with exactly as much benefit as one.
    def scan_tokens
      return if known.empty?

      source.each_line.with_index(1) do |text, line|
        text.scan(/[A-Za-z_][A-Za-z0-9_]*/) do |word|
          add('token', word, '', line) if known.include?(word)
        end
      end
    end
  end
end
