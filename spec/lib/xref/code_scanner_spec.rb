# -*- encoding : utf-8 -*-
require 'spec_helper'

# The code parser of the cross-reference index (the specification (the "how it
# is built" section).
#
# The spec exists not for coverage but because the rules here are subtle and
# break SILENTLY: the report goes on printing, just with different numbers. It
# broke that way twice within one session — so every example below closes a
# specific mistake that the index has already made once.
RSpec.describe Xref::CodeScanner do
  def scan(source, path: 'app/models/probe.rb', **options)
    described_class.new(path, source, **options).scan
  end

  def of(source, kind, path: 'app/models/probe.rb', **options)
    scan(source, path: path, **options).select { |ref| ref.kind == kind }
  end

  def pairs(refs)
    refs.map { |ref| [ref.token, ref.owner] }
  end

  describe 'parsed SQL is a fact' do
    it 'takes the table and the column out of a string parsed by the parser' do
      source = %(Xdm.execute("select login from big_users where user_id = 1"))

      expect(of(source, 'pg_table').map(&:token)).to eq(['big_users'])
      expect(pairs(of(source, 'pg_column'))).to include(%w[login big_users], %w[user_id big_users])
    end

    # "The column is used" does not tell a read from a write, and those are
    # different answers: 17 columns out of 71 in one table alone are written into
    # the void.
    it 'treats an update target as a write and the expression on the right as a read' do
      source = %(Xdm.execute("update big_users set g1 = g1 + 1 where user_id = 2"))

      expect(pairs(of(source, 'pg_column_write'))).to eq([%w[g1 big_users]])
      expect(pairs(of(source, 'pg_column'))).to contain_exactly(%w[g1 big_users], %w[user_id big_users])
    end

    it 'treats insert columns as a write on the DML table rather than on the only table of the query' do
      source = %(Xdm.execute("insert into big_users (login, g1) select name, flag from imports"))

      expect(pairs(of(source, 'pg_column_write')))
        .to contain_exactly(%w[login big_users], %w[g1 big_users])
      expect(of(source, 'pg_column').map(&:token)).to contain_exactly('name', 'flag')
    end

    it 'does not list a select as a write' do
      source = %(Xdm.execute("select login from big_users"))

      expect(of(source, 'pg_column_write')).to be_empty
    end

    it 'extracts a key inside jsonb together with the column' do
      source = %(Xdm.execute("select meta->>'status' from funnel_events"))

      expect(pairs(of(source, 'json_key'))).to eq([['status', 'funnel_events.meta']])
    end
  end

  describe 'a hole from interpolation' do
    # With the number one instead of `$1` the string
    # `"… from auth_sid#{sid}"` parsed as the table
    # `auth_sid1`: the index silently invented names the database does
    # not have.
    let(:sharded) do
      <<~'RUBY'
        Xdm.execute("select auth_sid from auth_sid#{user_id % 1000} where a = 1")
      RUBY
    end

    it 'keeps a table name assembled at runtime out of the facts' do
      expect(of(sharded, 'pg_table')).to be_empty
      expect(of(sharded, 'pg_table_guess').map(&:token)).to eq(['auth_sid'])
    end

    # An interpolation in a NAME position must not take the whole query into a
    # blind spot: a parameter is not legitimate there, so the second attempt
    # substitutes a marker name and everything else — columns, write targets,
    # joins — becomes visible. Over the tree that is 256 queries out of 731 which
    # previously yielded nothing at all.
    it 'still shows the columns of a query whose table name is assembled' do
      expect(of(sharded, 'sql_blind')).to be_empty
      expect(of(sharded, 'pg_column', known: Set.new(%w[auth_sid])).map(&:token))
        .to include('auth_sid')
    end

    it 'makes the blind spot only about the name when no letters of it are left' do
      source = %q(Xdm.execute("select user_id, photo_count from #{table} where sex = 2"))
      found = of(source, 'sql_blind')

      expect(found.size).to eq(1)
      expect(found.first.detail[:error]).to include('имя таблицы собрано интерполяцией целиком')
      expect(of(source, 'pg_column').map(&:token)).to include('user_id', 'photo_count', 'sex')
    end

    # Six rules that cut the blind spots from 731 down to 317. Each of them
    # closes A CLASS: one query with an interpolation in an awkward position took
    # the whole query into ignorance, together with its tables and columns.
    it 'lets the rest be seen with an interpolation in a condition' do
      source = %q(Xdm.execute("select user_id from member_types where member_type in (#{list}) #{cond}"))

      expect(of(source, 'pg_table').map(&:token)).to eq(['member_types'])
      expect(of(source, 'pg_column', known: Set.new(%w[user_id member_type])).map(&:token))
        .to include('user_id', 'member_type')
    end

    it 'still shows the table with an interpolation in an update assignment' do
      source = %q(Xdm.execute("update legacy_users set #{sets} where user_id='#{id}'"))

      expect(of(source, 'pg_table').map(&:token)).to eq(['legacy_users'])
      expect(of(source, 'pg_column', known: Set.new(%w[user_id])).map(&:token)).to include('user_id')
    end

    it 'handles an interpolation in the column definitions of a create table' do
      source = %q(Xdm.execute("create table suspended_mail_flat (#{columns})"))

      expect(of(source, 'pg_table').map(&:token)).to eq(['suspended_mail_flat'])
      expect(of(source, 'sql_blind')).to be_empty
    end

    it 'treats a literal #{} in single quotes as a hole rather than as garbage' do
      source = %q(sql = 'select user_id from big_users where sex=#{sex}')
      options = { known: Set.new(%w[big_users user_id sex]) }

      expect(of(source, 'pg_table', **options).map(&:token)).to eq(['big_users'])
      expect(of(source, 'sql_blind', **options)).to be_empty
    end

    it 'does not count a phrase that starts with a keyword as a query' do
      source = %q(t = 'Select a valid review status')

      expect(of(source, 'sql_blind')).to be_empty
      expect(of(source, 'sql_piece').size).to eq(1)
    end

    # A query in a heredoc: the blind record sits on the line where the query
    # STARTS while the hole sits on the line of the interpolation itself, that
    # is, one line below. Matching by line number never found them, and of 166
    # such places NOT ONE was resolved — while `TABLE` is assigned in the same
    # file. Now the record carries the root itself.
    it 'finds a table name from a constant even in a heredoc where the lines do not match' do
      source = <<~'RUBY'
        class Probe
          TABLE = 'identity_audit_events'
          def self.recent(user_id)
            rows(<<~SQL.squish)
              select id, stage
                from #{TABLE}
               where user_id='#{user_id.to_i}'
            SQL
          end
        end
      RUBY
      options = { known: Set.new(%w[identity_audit_events id stage user_id]) }

      expect(of(source, 'pg_table_guess', **options).map(&:token))
        .to eq(['identity_audit_events'])
      expect(of(source, 'sql_blind', **options).first.detail[:resolved])
        .to eq('identity_audit_events')
    end

    it 'finds a table name from a variable through the assignment, including a choice of two' do
      source = <<~'RUBY'
        class Probe
          def run
            table = slow? ? 'events_log2' : 'queries_log'
            Xdm.execute("select count(*) from #{table} where id = 1")
          end
        end
      RUBY
      options = { known: Set.new(%w[queries_log events_log2 id]) }

      expect(of(source, 'pg_table_guess', **options).map(&:token))
        .to contain_exactly('events_log2', 'queries_log')
      expect(of(source, 'sql_blind', **options).first.detail[:resolved]).to include('queries_log')
    end

    # A fix that created false findings of its own: when one of the table names
    # is assembled at runtime, the remaining table is "the only one" only in
    # appearance, and unqualified columns were attributed to it. Six false
    # "columns that do not exist".
    it 'attributes an unqualified column to nobody when one of the table names is assembled' do
      source = %q(Xdm.execute("select user_id from top_gallery#{add} where show=1 and user_id not in (select user_id from member_types where member_type=79)"))
      options = { known: Set.new(%w[user_id show member_type member_types]) }

      expect(of(source, 'pg_table', **options).map(&:token)).to eq(['member_types'])
      expect(of(source, 'pg_column', **options).select { |ref| ref.token == 'show' }.map(&:owner))
        .to eq([''])
    end

    it 'keeps the expression, the root and the position in the query' do
      hole = of(sharded, 'sql_hole').first

      expect(hole.token).to eq('user_id')
      expect(hole.owner).to eq('glue')
      expect(hole.detail[:expr]).to eq('user_id % 1000')
      expect(hole.detail[:blind]).to be(true)
    end

    it 'counts the second element of an in (…) list as that position, not only the first' do
      source = <<~'RUBY'
        Xdm.execute("select * from flowers where home_city in (#{one}, #{two})")
      RUBY

      expect(pairs(of(source, 'sql_hole'))).to contain_exactly(%w[one in_list], %w[two in_list])
    end

    it 'tells a value, quotes and a whole condition apart' do
      source = <<~'RUBY'
        Xdm.execute("select * from big_users where id = #{id} and site = '#{site}' and #{cond}")
      RUBY

      expect(pairs(of(source, 'sql_hole')))
        .to contain_exactly(%w[id value], %w[site quoted], %w[cond condition])
    end

    # Prism returns a line-continuation concatenation as nested nodes. While it
    # was not unwrapped, each part collapsed into one hole entirely: out of
    # `"INSERT … VALUES " "(#{a}, #{b})"` came `INSERT … VALUES $1`, that is,
    # half the query vanished and the query went into the blind spots.
    it 'unwraps strings glued by a line continuation' do
      source = <<~'RUBY'
        sql = 'INSERT INTO guest_events (id, ts) VALUES ' \
              "(#{uuid}, #{stamp})"
      RUBY

      expect(of(source, 'pg_table').map(&:token)).to eq(['guest_events'])
      expect(of(source, 'sql_blind')).to be_empty
      expect(pairs(of(source, 'sql_hole'))).to contain_exactly(%w[uuid values], %w[stamp values])
    end

    it 'gives every hole a line of its own rather than the start of the literal' do
      source = <<~'RUBY'
        Xdm.execute(%|SELECT id FROM big_users
          WHERE #{cond}
          AND age > #{age}|)
      RUBY

      expect(of(source, 'sql_hole').map { |ref| [ref.token, ref.lines] })
        .to contain_exactly(['cond', [2]], ['age', [3]])
    end
  end

  describe 'a fragment of a query' do
    it 'records a hole in a piece of a condition with a mark' do
      source = <<~'RUBY'
        param_ar << "user_id in (#{additional_sql})"
      RUBY
      hole = of(source, 'sql_hole').first

      expect([hole.token, hole.owner]).to eq(%w[additional_sql in_list])
      expect(hole.detail[:fragment]).to be(true)
    end

    # The `name = …` branch in the fragment criterion let log lines and URL
    # parameters into the index: sixteen false findings out of a hundred and
    # seven.
    it 'does not count a log line and URL parameters as a fragment' do
      source = <<~'RUBY'
        logger.info "trace=#{id} n=#{count} ver=#{version}"
        redirect_to "/account?flm=#{flag}&intp=#{mode}"
        Rails.cache.write "key=#{user_id}", value
      RUBY

      expect(of(source, 'sql_hole')).to be_empty
    end

    it 'does not take a fragment with no strong sign of SQL' do
      # `%q` rather than `%`: otherwise the interpolation happens inside the
      # spec itself, the parser gets a string with no hole and the example passes
      # for the wrong reason.
      expect(of(%q(ar << "and #{cond} ещё что-то"), 'sql_hole')).to be_empty
      expect(of(%q(ar << "and #{cond} in (select id from big_users)"), 'sql_hole')).not_to be_empty
    end
  end

  describe 'method declarations' do
    let(:source) do
      <<~'RUBY'
        class Probe
          def plain; end
          private def hidden; end
          def after_private; end
          private
          def below; end
          public
          def again; end
          class << self
            private
            def singleton_private; end
          end
          def self.named; end
          private_class_method :named
        end
        class Other
          def declared_later; end
          private :declared_later
          def still_public; end
        end
      RUBY
    end

    it 'knows all four ways of setting visibility' do
      found = of(source, 'def').to_h { |ref| [ref.token, ref.detail[:visibility]] }

      expect(found).to eq(
        'plain' => 'public', 'hidden' => 'private', 'after_private' => 'public',
        'below' => 'private', 'again' => 'public', 'singleton_private' => 'private',
        'named' => 'private', 'declared_later' => 'private', 'still_public' => 'public'
      )
    end

    it 'marks class methods declared through class << self' do
      found = of(source, 'def').to_h { |ref| [ref.token, ref.detail[:singleton]] }

      expect(found['singleton_private']).to be(true)
      expect(found['named']).to be(true)
      expect(found['plain']).to be(false)
    end

    # "The body contains a query" is true of almost any model (2,123 methods out
    # of 23,689), "returns a query" of 75. By the first one half the repository
    # lands in the report.
    it 'tells "returns a query" from "there is a query inside"' do
      source = <<~'RUBY'
        class Probe
          def whole
            <<~SQL.squish
              select user_id from sessions_live2
            SQL
          end

          def part
            "(user_id in (select user_id from sessions_live3))"
          end

          def only_runs
            Xdm.execute('select 1 from big_users')
            42
          end
        end
      RUBY
      found = of(source, 'def').to_h { |ref| [ref.token, ref.detail] }

      expect(found['whole'].values_at(:returns, :returns_part, :sql)).to eq([true, false, true])
      expect(found['part'].values_at(:returns, :returns_part)).to eq([false, true])
      expect(found['only_runs'].values_at(:returns, :returns_part, :sql)).to eq([false, false, true])
    end

    it 'remembers the parameters: through them a hole is traced to the caller' do
      source = <<~'RUBY'
        def make_param(sql, table, limit: 10)
          ["user_id in (#{sql})"]
        end
      RUBY
      found = of(source, 'def').first

      expect(found.detail[:params]).to include('sql', 'table', 'limit')
    end
  end

  # SQL lives not only in the tree: a rewrite rule is code in the database, and
  # its body changes the meaning of an insert. An accumulating rule READS the
  # column it increments, and without parsing the body that column would be
  # listed as unread.
  describe 'the body of a rewrite rule' do
    let(:rule) do
      <<~SQL
        CREATE RULE insert_stat AS ON INSERT TO stat
          WHERE new.flag = true
          DO INSTEAD UPDATE stat SET hits = stat.hits + new.hits
           WHERE stat.day = new.day
      SQL
    end

    it 'sees both the write and the read of the same column' do
      refs = described_class.new('rule.sql', rule).scan

      writes = refs.select { |ref| ref.kind == 'pg_column_write' }
      reads = refs.select { |ref| ref.kind == 'pg_column' && ref.owner == 'stat' }
      expect(pairs(writes)).to include(%w[hits stat])
      expect(reads.map(&:token)).to include('hits')
    end

    it 'does not confuse the new row with a table' do
      refs = described_class.new('rule.sql', rule).scan
      incoming = refs.select { |ref| ref.kind == 'pg_column' && ref.owner == 'new' }

      expect(incoming.map(&:token)).to include('hits', 'flag')
    end

    it 'gives an accumulation no source column: the value is computed in place' do
      found = described_class.new('rule.sql', rule).scan.select { |ref| ref.kind == 'col_lineage' }

      expect(found).to be_empty
    end
  end

  # Where the value of a column arrives from. The matching is positional —
  # exactly as the database itself does it.
  describe 'value lineage' do
    it 'has insert … select yield a "where to ← where from" pair by position' do
      source = <<~'RUBY'
        Xdm.execute("insert into search_index (user_id, name, flag)
                     select u.user_id, u.login, now() from legacy_users u")
      RUBY
      found = of(source, 'col_lineage').to_h { |ref| [ref.token, ref.owner] }

      # `now()` has no source column, so there is no pair for `flag` at all: the
      # absence reads as "computed in place".
      expect(found).to eq('search_index.user_id' => 'legacy_users.user_id',
                          'search_index.name' => 'legacy_users.login')
    end

    it 'has update … from yield a pair too, with the alias resolved' do
      source = <<~'RUBY'
        Xdm.execute("update big_users set asset_key = p.key from photos p
                     where p.user_id = big_users.user_id")
      RUBY
      found = of(source, 'col_lineage').first

      expect([found.token, found.owner, found.detail[:via]])
        .to eq(['big_users.asset_key', 'photos.key', 'update-from'])
    end

    it 'gives an insert with values no lineage at all' do
      source = %(Xdm.execute("insert into big_users (user_id, login) values (1, 'x')"))

      expect(of(source, 'col_lineage')).to be_empty
    end
  end

  # A column list substituted into a query as a whole is the only place such a
  # column is named. Without this kind 35 columns of one table out of 71 looked
  # dead.
  describe 'column lists' do
    let(:known) { Set.new(%w[user_id login sex paid_until paid_from client_segment]) }

    it 'takes both a comma-separated string and an array of words' do
      source = <<~'RUBY'
        class Probe
          FIELDS = 'user_id,login, sex'
          ADD = ['paid_until', 'paid_from', 'client_segment']
        end
      RUBY
      found = of(source, 'col_list', known: known).to_h { |ref| [ref.token, ref.detail[:columns]] }

      expect(found['FIELDS']).to eq(%w[user_id login sex])
      expect(found['ADD']).to eq(%w[paid_until paid_from client_segment])
    end

    it 'does not count an ordinary string or an ordinary array as a column list' do
      source = <<~'RUBY'
        NOTE = 'привет, мир, как дела'
        WORDS = %w[один два три четыре]
      RUBY

      expect(of(source, 'col_list', known: known)).to be_empty
    end

    it 'applies the threshold: two familiar names are too few, three are enough' do
      expect(of(%(PAIR = 'user_id,login'), 'col_list', known: known)).to be_empty
      expect(of(%(TRIO = 'user_id,login,sex'), 'col_list', known: known).size).to eq(1)
    end
  end

  describe 'columnar-store wrappers' do
    # By the `hb_` prefix `hb_mail_info('new', …)` landed in the index, where the
    # first argument is a mail folder, and tables `new`, `clean`, `friends` were
    # created.
    it 'treats the first argument as a table only for wrappers from the list' do
      source = <<~'RUBY'
        hb_mail_info('new', user_id)
        ColumnStore.hb_execute('member_info', key, { 'a:ed' => 1 })
      RUBY

      # The list of wrappers is named BY THE EXAMPLE rather than taken from the
      # configuration of whichever tree the spec happens to run in: a spec that
      # leans on the host project is green in one tree and red in another, and
      # it proves nothing in either.
      allow(Xref).to receive(:idioms)
        .and_return(Xref::IDIOM_DEFAULTS.merge(table_first: ['hb_execute']))

      expect(of(source, 'hb_table').map(&:token)).to eq(['member_info'])
      expect(pairs(of(source, 'hb_column'))).to eq([['a:ed', 'member_info']])
    end

    it 'calls a dynamic table name an expression rather than a table' do
      source = <<~'RUBY'
        ColumnStore.hb_execute("photos_#{kind}", key)
      RUBY
      allow(Xref).to receive(:idioms)
        .and_return(Xref::IDIOM_DEFAULTS.merge(table_first: ['hb_execute']))
      found = of(source, 'hb_dynamic').first

      expect(of(source, 'hb_table')).to be_empty
      expect(found.detail[:expr]).to eq('kind')
      expect(found.detail[:skeleton]).to eq('photos_*')
    end
  end

  describe 'renders' do
    it 'sees the old arrow form and both branches of a ternary' do
      source = <<~'RUBY'
        render :partial => 'account/profile'
        render partial: cond ? 'gal/one' : 'gal/two'
      RUBY

      expect(of(source, 'render_ref').map(&:token))
        .to contain_exactly('account/profile', 'gal/one', 'gal/two')
    end

    it 'turns an interpolated name into a pattern rather than an invention' do
      source = <<~'RUBY'
        render :partial => "theme_old/layouts/#{chosen}"
      RUBY
      found = of(source, 'render_dynamic').first

      expect(found.owner).to eq('skeleton')
      # The underscore is escaped with a tilde: in LIKE an underscore is a
      # wildcard, and view names are full of them.
      expect(found.detail[:glob]).to eq('theme~_old/layouts/%')
      expect(found.detail[:root]).to eq('chosen')
    end

    it 'calls a name sitting entirely in a variable a blind spot with no pattern' do
      found = of('render @partial', 'render_dynamic').first

      expect(found.token).to eq('@partial')
      expect(found.owner).to eq('')
    end

    it 'does not count page text and comments as a render' do
      source = <<~'RUBY'
        # render 'old/thing'
        notice = 'does not render anything'
      RUBY

      expect(of(source, 'render_ref')).to be_empty
      expect(of(source, 'render_dynamic')).to be_empty
    end

    # The interface-mode prefix STAYS in the logical name: what merges the modes
    # is not the parser but the suffix comparison in `v_render_edges` (`right()`,
    # not LIKE — view names are full of underscores). So `render 'searchedit/x'`
    # leads into every mode at once while the file name is not lost.
    it 'builds the logical view name: no app/views, no underscore, no extensions' do
      expect(described_class.view_logical_name('app/views/theme_old/searchedit/_sex_with_gal.html.erb'))
        .to eq('theme_old/searchedit/sex_with_gal')
      expect(described_class.view_logical_name('app/views/feed/show_items.rss.builder'))
        .to eq('feed/show_items')
    end
  end

  # Control check B17 from the registry of problems of agent work on a large
  # codebase: "does a disabled parser yield incompleteness rather than success".
  # Without it zero findings is indistinguishable from "nobody looked".
  # A document is as much a source of statements about the tree as code is, and
  # it ages silently. The main danger of the parse is A FALSE ALARM: documents
  # are full of sketches and quotations, and a parse that calls them defects
  # issued 137 findings while fourteen were real.
  # An environment key name in A CONSTANT is a widespread form, and without it
  # the report lied in both directions: 30-plus settings were listed as "read by
  # nobody" (including the ones that are read), and a key missing from the
  # environment would not have been found either.
  describe 'an environment key through a constant' do
    it 'takes the name from a constant holding a string literal' do
      source = <<~'RUBY'
        class Probe
          LEASE_ENV = 'SETTINGS_MEDIA_LEASE_SECONDS'
          def lease
            ENV[LEASE_ENV].to_i
          end
        end
      RUBY

      expect(of(source, 'env_key').map(&:token)).to eq(['SETTINGS_MEDIA_LEASE_SECONDS'])
    end

    # A constant assembled by interpolation gives no whole name in the source —
    # and inventing one is not allowed: that is a different class of ignorance.
    it 'does not count an assembled constant name as a key' do
      source = <<~'RUBY'
        class Probe
          PREFIX = 'SETTINGS'
          LEASE_ENV = "#{PREFIX}_LEASE"
          def lease
            ENV[LEASE_ENV].to_i
          end
        end
      RUBY

      expect(of(source, 'env_key')).to be_empty
    end

    # In this tree the constants are frozen (`= 'X'.freeze`), and that is
    # already A CALL rather than a literal: by the rule without the tail not one
    # of the twelve would have qualified.
    it 'sees the name through .freeze as well' do
      source = <<~'RUBY'
        class Probe
          ENABLED_ENV = 'SOCIAL_PHOTO_IMPORT_ENABLED'.freeze
          def on?
            ENV[ENABLED_ENV].to_s == '1'
          end
        end
      RUBY

      expect(of(source, 'env_key').map(&:token)).to eq(['SOCIAL_PHOTO_IMPORT_ENABLED'])
    end

    it 'still sees a fallback value through a constant' do
      source = <<~'RUBY'
        KEY = 'SETTINGS_RETRIES'
        ENV.fetch(KEY, '3')
      RUBY

      expect(of(source, 'env_key').map(&:token)).to eq(['SETTINGS_RETRIES'])
      expect(of(source, 'env_default').map(&:token)).to eq(['SETTINGS_RETRIES'])
    end
  end

  # STYLE CLASSES. The answer "the class is not needed" is more dangerous here
  # than any other in this layer: in this tree class names are assembled all the
  # time (2,420 places where they are assembled IN FULL alone). The examples
  # below close both sides — the finding and the blindness.
  describe 'classes from the markup and from code' do
    it 'takes literals and turns an interpolation into a pattern' do
      source = %(<div class="card card-big"><span class="btn btn-<%= kind %>">x</span></div>\n)
      refs = scan(source, path: 'app/views/x.html.erb')

      expect(refs.select { |r| r.kind == 'html_class' }.map(&:token))
        .to contain_exactly('card', 'card-big', 'btn')
      expect(refs.select { |r| r.kind == 'html_class_pattern' }.map(&:token)).to eq(['btn-$1'])
    end

    # THE ORDER DECIDES: splitting by spaces before masking the tags puts `kind`
    # out of `<%= kind %>` into the index as a CLASS that the styles do not have.
    it 'does not count a variable name as a class' do
      refs = scan(%(<i class="btn btn-<%= kind %>"></i>\n), path: 'app/views/x.html.erb')

      expect(refs.select { |r| r.kind == 'html_class' }.map(&:token)).not_to include('kind', '<%=')
    end

    it 'calls a name assembled in full a blind spot' do
      refs = scan(%(<i class="<%= whole %>"></i>\n), path: 'app/views/x.html.erb')

      expect(refs.select { |r| r.kind == 'html_class_dynamic' }).not_to be_empty
      expect(refs.select { |r| r.kind == 'html_class' }).to be_empty
    end

    it 'treats a class from code at runtime as the same kind of use' do
      refs = scan("el.classList.add('open');\n$(x).addClass('shown hidden');\n",
                  path: 'app/javascript/x.js')

      expect(refs.select { |r| r.kind == 'html_class' }.map(&:token))
        .to contain_exactly('open', 'shown', 'hidden')
    end

    it 'records a pack name from a template and marks an assembled one' do
      refs = scan("<%= modern_stylesheet_pack_tag 'theme_new' %>\n" \
                  "<%= esbuild_pack_asset_path(\"pack_\#{name}.css\") %>\n",
                  path: 'app/views/layouts/theme_new.html.erb')

      expect(refs.select { |r| r.kind == 'pack_ref' }.map(&:token)).to eq(['theme_new'])
      expect(refs.select { |r| r.kind == 'pack_dynamic' }).not_to be_empty
    end
  end

  # THE HABITS OF THE TREE come from the configuration rather than from the
  # parser. Baked in, they made the tool unportable: in a second project the
  # parse counted by somebody else's names and somebody else's wrappers (and
  # captioned its answer "in 18 languages" about a tree with two).
  describe 'the habits of the tree are configurable' do
    def with_idioms(extra)
      allow(Xref).to receive(:idioms).and_return(Xref::IDIOM_DEFAULTS.merge(extra))
    end

    # The name of the receiver decides the fate of a VARIABLE key:
    # `something[field]` in Ruby is a column read, an array access and a file
    # glob all at once. Until the name is declared a habit of the tree, this is
    # not a column read but noise (that is what overstated the count of our own
    # ignorance twelvefold).
    it 'takes the result-row name from the configuration rather than from the parser' do
      source = "def show(anketa, field)\n  anketa[field]\nend\n"

      with_idioms(row_names: %w[row line])
      expect(of(source, 'key_dynamic')).to be_empty

      with_idioms(row_names: %w[row line anketa])
      expect(of(source, 'key_dynamic').map(&:token)).to eq(['[]'])
    end

    it 'treats as a columnar-store wrapper only what the configuration names' do
      source = "Xdm.hb_execute('clip_store', 'cf:x')\n"
      options = { known: Set.new(%w[clip_store]) }

      with_idioms(table_first: [])
      expect(of(source, 'hb_table', **options)).to be_empty

      with_idioms(table_first: %w[hb_execute])
      expect(of(source, 'hb_table', **options).map(&:token)).to eq(['clip_store'])
    end

    # The "non-ASCII means prose" filter is a rule of a RUSSIAN tree. In a
    # project written entirely in English it has to be switched off, otherwise it
    # never fires once.
    it 'allows the "non-ASCII means prose" rule to be switched off' do
      source = %q(t = 'Select a valid review status')

      with_idioms(prose_is_non_ascii: true)
      expect(of(source, 'sql_piece').size).to eq(1)
    end
  end

  # The gate of the walk: without the extension in the list a layer is not
  # scanned AT ALL, and that is the worst kind of breakage — the report does not
  # stay silent, it declares the working broken.
  describe 'TypeScript is the same class as JavaScript' do
    it 'puts .ts, .tsx and .mts into the js class' do
      %w[app/javascript/application.ts app/javascript/x.tsx config/y.mts].each do |path|
        expect(described_class.language(path)).to eq('js'), path
      end
    end

    it 'takes the name of an anonymous class from the file without its extension' do
      refs = scan("export default class extends Controller {\n  go() {}\n}\n",
                  path: 'app/javascript/controllers/theme_controller.ts')

      expect(refs.select { |r| r.kind == 'js_class' }.map(&:token)).to eq(['ThemeController'])
      expect(refs.select { |r| r.kind == 'stimulus_class' }.map(&:token)).to eq(['ThemeController'])
    end
  end

  describe 'parsing documentation' do
    def doc(source, kind, path: 'doc/проба.md', **options)
      described_class.new(path, source, **options).scan.select { |ref| ref.kind == kind }
    end

    it 'makes a table mention in a document its own kind rather than an access to the table' do
      source = "Запрос:\n\n```sql\nselect contact from member_contacts where id=1\n```\n"
      options = { known: Set.new(%w[member_contacts contact]) }

      expect(doc(source, 'doc_table', **options).map(&:token)).to eq(['member_contacts'])
      expect(doc(source, 'doc_column', **options).map(&:token)).to eq(['contact'])
      # And this is the main point: "it is written in a document" does not make a
      # column used.
      expect(doc(source, 'pg_table', **options)).to be_empty
      expect(doc(source, 'pg_column', **options)).to be_empty
    end

    it 'counts a name from the database in backticks as named and in prose as not' do
      options = { known: Set.new(%w[big_users]) }

      expect(doc('таблица `big_users` вот', 'doc_name', **options).map(&:token)).to eq(['big_users'])
      expect(doc('таблица big_users вот', 'doc_name', **options)).to be_empty
    end

    it 'calls a missing path a finding only when it is anchored to the root' do
      source = "файлы `app/models/no_such_file.rb` и `user_profile.rb`\n"
      found = doc(source, 'doc_path').to_h { |ref| [ref.token, ref.owner] }

      expect(found['app/models/no_such_file.rb']).to eq('НЕТ ТАКОГО ФАЙЛА')
      expect(found['user_profile.rb']).to eq('похоже на путь')
    end

    # Five classes, and each of them was once listed as a "broken example".
    # A contour helper with a literal: the template name is assembled by it
    # (contour, controller, name), but the last segment is named directly — and
    # candidates are findable through it. There are 76 such renders out of 258
    # "blind" ones.
    it 'calls a render through a contour helper with a literal a pattern rather than blindness' do
      source = "<% render(:partial => censors_partial_path('show_next')) %>\n"
      refs = scan(source, path: 'app/views/censors/index.html.erb')
      dynamic = refs.select { |ref| ref.kind == 'render_dynamic' }

      expect(dynamic.map(&:owner)).to eq(['skeleton'])
      expect(dynamic.first.token).to eq('*show_next')
      expect(dynamic.first.detail[:glob]).to eq('%show~_next')
    end

    # The other side: a ROUTE helper with a literal is not a template, and a
    # short segment puts every other template into the candidates.
    it 'does not call a route helper or a short segment a pattern' do
      ["<% render(:partial => user_path('profile')) %>\n",
       "<% render(:partial => gal_partial_path('abc')) %>\n"].each do |source|
        dynamic = scan(source, path: 'app/views/gal/index.html.erb')
                  .select { |ref| ref.kind == 'render_dynamic' }

        expect(dynamic.map(&:owner)).to eq(['']), "узором стало: #{source.strip}"
      end
    end

    it 'does not call a sketch with a human omission a defect' do
      [
        "```sql\nupdate t set seen = now() where src = <номер ДЦ>\n```\n",
        "```sql\nselect a from t where id in (…)\n```\n",
        "```sql\nupdate member_contacts set status=19 where contact=<email>\n```\n"
      ].each do |source|
        expect(doc(source, 'doc_code_sketch')).not_to be_empty, "не набросок: #{source.inspect}"
        expect(doc(source, 'doc_code_broken')).to be_empty
      end
    end

    it 'does not call a fragment cut off mid-branch a defect' do
      source = "```ruby\nif a == 1\n  x = 2\nelsif b\n```\n"

      expect(doc(source, 'doc_code_excerpt')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    it 'does not parse a patch as code' do
      source = "```ruby\n-  было = 1\n+  стало = 2\n```\n"

      expect(doc(source, 'doc_code_patch')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    # A one-line patch: a context line and one line with `+`. Two markers do not
    # accumulate here, and the block landed among the broken examples.
    it 'recognises a patch with one marker by parsing the stripped characters' do
      source = "```ruby\n def unblock_serious\n+    return\n```\n"

      expect(doc(source, 'doc_code_patch')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    # The other side of the same check: a `-1` in ordinary code does not make it
    # a patch.
    it 'does not count a minus in an expression as a patch' do
      source = "```ruby\nx = 1\n-1.upto(3) { |i| p i }\n```\n"

      expect(doc(source, 'doc_code_patch')).to be_empty
    end

    it 'counts two lines from the middle of a hash as a fragment' do
      source = "```ruby\n'title_key' => 'index_page.diff_goals',\n'body_key'  => 'index_page.search_by_goals'\n```\n"

      expect(doc(source, 'doc_code_excerpt')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    # A listing of places where the file name is named in the paragraph rather
    # than in the block: the lines start with a bare line number, and Ruby reads
    # `:165` as an invalid character.
    it 'counts a listing of lines by number as a sketch' do
      source = "```ruby\n:165   fin = Pricing.interest_search(x) || [1,2,3]\n:170   fin = Pricing.interest_search(y) || [1,2,3]\n```\n"

      expect(doc(source, 'doc_code_sketch')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    it 'completes a query fragment with a prefix and reads the table out of it' do
      source = "```sql\nfrom member_contacts c join big_users u on u.user_id=c.user_id\n```\n"
      options = { known: Set.new(%w[member_contacts big_users]) }

      expect(doc(source, 'doc_table', **options).map(&:token))
        .to contain_exactly('member_contacts', 'big_users')
      expect(doc(source, 'doc_code_fragment', **options)).not_to be_empty
    end

    it 'completes a table composition written without the words create table too' do
      source = "```sql\nmailbox_contacts (\n  id uuid primary key,\n  user_id bigint\n)\n```\n"

      expect(doc(source, 'doc_table', known: Set.new(%w[mailbox_contacts])).map(&:token))
        .to eq(['mailbox_contacts'])
    end

    it 'parses a query template with named placeholders' do
      source = "```sql\ninsert into partner_tickets (id, user_id) values (:uuid7, :user_id)\n```\n"

      expect(doc(source, 'doc_table', known: Set.new).map(&:token)).to eq(['partner_tickets'])
      expect(doc(source, 'doc_code_broken', known: Set.new)).to be_empty
    end

    it 'calls a foreign dialect a dialect rather than a broken example' do
      source = "```sql\nALTER TABLE lm.requests MODIFY COLUMN `sql.text` Array(String) CODEC(ZSTD(3));\n```\n"

      expect(doc(source, 'doc_code_dialect')).not_to be_empty
      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    # The language label lies constantly: a block labelled `ruby` holds a query.
    it 'trusts the content of a block rather than its language label' do
      source = "```ruby\nselect id from member_contacts where user_id=1\n```\n"

      expect(doc(source, 'doc_table', known: Set.new(%w[member_contacts])).map(&:token))
        .to eq(['member_contacts'])
    end

    it 'does not call markup inside an erb block a broken example' do
      source = "```erb\n<a href=\"/x\" data-controller=\"fragment-request\">ссылка</a>\n```\n"

      expect(doc(source, 'doc_code_broken')).to be_empty
    end

    # The prose of a document does not enter the candidate layer: 157 MB of
    # documents would drown the answers in matches for every name from the
    # database.
    it 'does not build the word-candidate layer for a document' do
      expect(doc('везде big_users и contact', 'token', known: Set.new(%w[big_users contact]))).to be_empty
    end

    it 'calls Ruby that genuinely does not parse broken' do
      source = "```ruby\nx = {1 => }\n```\n"

      expect(doc(source, 'doc_code_broken').map(&:owner)).to eq(['ruby'])
    end
  end

  # Two names that ARE NOT COLUMNS even though they stand in a column position.
  # Both produced a false finding "the code reads a column the table does not
  # have" — that is, the report called a working query an error.
  describe 'output names rather than columns' do
    # What is checked is THE OWNER rather than the presence of a record: the name
    # stays visible but is not attributed to the table — otherwise the report
    # says "the code reads a column the table does not have" about a working
    # query.
    it 'does not attribute the implicit column name of an aggregate to the table' do
      source = %q(Xdm.execute("select count(*), controller from route_misses group by controller order by count desc"))
      options = { known: Set.new(%w[route_misses controller count]) }

      expect(pairs(of(source, 'pg_column', **options))).to include(%w[controller route_misses])
      expect(pairs(of(source, 'pg_column', **options))).to include(['count', ''])
    end

    it 'does not attribute a function alias in from to the table' do
      source = <<~'RUBY'
        Xdm.execute("select uc.user_id, m[1] as line from member_comments uc, lateral regexp_matches(uc.comment_text, 'x', 'g') m where uc.comment_id=1")
      RUBY
      options = { known: Set.new(%w[member_comments user_id comment_text comment_id m]) }

      expect(pairs(of(source, 'pg_column', **options))).to include(%w[user_id member_comments])
      expect(pairs(of(source, 'pg_column', **options))).to include(['m', ''])
    end

    # The other side: the rule must not silence A REAL column with the same
    # name. As long as there is no unnamed aggregate in the output list, `count`
    # is a column of its table and it does have an owner.
    it 'does not silence a real column named like a function' do
      source = %q(Xdm.execute("select count from route_misses where count > 1"))
      options = { known: Set.new(%w[route_misses count]) }

      expect(pairs(of(source, 'pg_column', **options))).to include(%w[count route_misses])
    end
  end

  describe 'parsing with no SQL parser' do
    before { allow(described_class).to receive(:pg_query?).and_return(false) }

    it 'does not pass a table off as a fact and names the cause of the incompleteness' do
      source = %(Xdm.execute("select login from big_users where user_id = 1"))

      expect(of(source, 'pg_table')).to be_empty
      blind = of(source, 'sql_blind').first
      expect(blind.detail[:error]).to include('парсер')
    end

    it 'still yields a guess about the table name — but as a separate kind' do
      source = %(Xdm.execute("select login from big_users where user_id = 1"))

      expect(of(source, 'pg_table_guess').map(&:token)).to eq(['big_users'])
    end

    it 'keeps the holes and their position in the query visible without the parser' do
      source = <<~'RUBY'
        Xdm.execute("select * from big_users where id in (#{ids.join(',')})")
      RUBY

      expect(pairs(of(source, 'sql_hole'))).to eq([%w[ids in_list]])
    end
  end

  describe 'candidates and assignments' do
    it 'treats a name from the database in text as a candidate, one row per file' do
      source = "# status status status\nx = 'status'"

      found = of(source, 'token', known: Set.new(%w[status])).first
      expect([found.token, found.count]).to eq(['status', 4])
    end

    # Control check B02: "does it tell a column from a variable of the same
    # name". That is what makes a text search useless: a short column name turns
    # out to be a variable name as well, and the name of a node in the
    # infrastructure too.
    it 'does not turn a variable of the same name into a column' do
      source = <<~'RUBY'
        def pick
          login = params['login']
          login.to_s.strip
        end
      RUBY
      options = { known: Set.new(%w[login]) }

      expect(of(source, 'pg_column', **options)).to be_empty
      expect(of(source, 'ar_column', **options)).to be_empty
      expect(of(source, 'token', **options).map(&:token)).to eq(['login'])
    end

    it 'makes the same column in a parsed query a fact with an owner' do
      source = %(Xdm.execute("select login from big_users where login <> ''"))

      expect(pairs(of(source, 'pg_column', known: Set.new(%w[login])))).to eq([%w[login big_users]])
    end

    it 'binds a column from AR arguments to the table of the model' do
      source = 'BigUser.where(g1: 1).order(:opt2_1)'
      options = { known: Set.new(%w[g1 opt2_1]), model_tables: { 'BigUser' => 'big_users' } }

      expect(pairs(of(source, 'ar_column', **options)))
        .to contain_exactly(%w[g1 big_users], %w[opt2_1 big_users])
    end

    # Both mistakes below were found by one check — "the code reads a column the
    # table does not have in any environment". Both led in the dangerous
    # direction: they invented a column that does not exist and thereby spoiled
    # the answer "what can be dropped".
    it 'treats a qualified star as a star rather than as a column named after the alias' do
      source = %(Xdm.execute("select ue.* from member_events ue where ue.user_id = 1"))

      expect(pairs(of(source, 'pg_column'))).to eq([%w[user_id member_events]])
      expect(pairs(of(source, 'pg_select_star'))).to eq([['*', 'member_events']])
    end

    it 'does not bind an unqualified column to the subquery table when from holds a subquery' do
      source = %(Xdm.execute("select b, count(*) from (select id, ntile(4) over () as b from media) t group by b"))

      expect(of(source, 'pg_column').map(&:owner).uniq).to eq([''])
      expect(of(source, 'pg_table').map(&:token)).to eq(['media'])
    end

    it 'still makes the only table the owner when there is no subquery' do
      source = %(Xdm.execute("select b from media where id = 1"))

      expect(pairs(of(source, 'pg_column'))).to contain_exactly(%w[b media], %w[id media])
    end

    # The record is not thrown away but left WITHOUT an owner: an alias name may
    # coincide with a real column (`select coalesce(a,0) as a … where a > 1`),
    # and losing such a read is not allowed. Inventing an owner is what is not
    # allowed.
    it 'gives an alias of a computation in order by no table owner' do
      source = %(Xdm.execute("select *, abs(t - 1) as abs from rates_feed order by abs limit 10"))
      found = pairs(of(source, 'pg_column'))

      expect(found).to include(['abs', ''])
      expect(found).to include(%w[t rates_feed])
      expect(pairs(of(source, 'pg_select_star'))).to eq([['*', 'rates_feed']])
    end

    # The decisive kind for the question "which fields we do not use in the
    # code". A name in a field list is NOT a use: the list is named once and for
    # every column at once. While this kind did not exist the report answered
    # "the direction was not traced" and hid the answer — nothing takes
    # `member_photo` while `member_messenger` is taken in one place, and those are
    # different things.
    it 'treats taking a value by key as a use of the column' do
      source = %q(x = @info['member_messenger']; y = row.fetch(:sex))
      options = { known: Set.new(%w[member_messenger sex]) }

      expect(of(source, 'key_read', **options).map(&:token)).to contain_exactly('member_messenger', 'sex')
    end

    # A read by key knew the NAME of the column and did not know whose table it
    # was — and the question is always asked about a table. Because of that
    # `select *` stayed an assumption: "this column is not read" was unknown for
    # any table ever selected with a star, and there are 150 of those.
    it 'gives a read by key inside a loop the table of its own query' do
      source = <<~RUBY
        res = ActiveRecord::Base.connection.select_all("select * from member_contacts where id=1").to_a
        res.each do |line|
          x = line['contact']
        end
      RUBY

      expect(pairs(of(source, 'key_read', known: Set.new(%w[member_contacts contact]))))
        .to eq([%w[contact member_contacts]])
    end

    it 'takes the table even when the query was held in a variable' do
      source = <<~RUBY
        sql = "select * from member_contacts where id=1"
        line = ActiveRecord::Base.connection.select_one(sql)
        x = line['contact']
      RUBY

      expect(pairs(of(source, 'key_read', known: Set.new(%w[member_contacts contact]))))
        .to eq([%w[contact member_contacts]])
    end

    # An error in the dangerous direction: attributing a column to one of the
    # tables of a join means inventing it, and that record is later used to
    # answer "the field is not used".
    it 'invents no owner for a read when the query holds two tables' do
      source = <<~RUBY
        res = ActiveRecord::Base.connection.select_all("select * from member_contacts u, big_users d where u.user_id=d.user_id").to_a
        res.each { |line| x = line['contact'] }
      RUBY

      expect(pairs(of(source, 'key_read', known: Set.new(%w[member_contacts big_users contact]))))
        .to eq([['contact', '']])
    end

    # A loop parameter lives only inside its loop. Without restoring the
    # previous value the second loop would attribute its reads to the table of
    # the first.
    it 'carries no table for a parameter name outside its own loop' do
      source = <<~RUBY
        a = ActiveRecord::Base.connection.select_all("select * from member_contacts").to_a
        a.each { |line| x = line['contact'] }
        b = ActiveRecord::Base.connection.select_all("select * from big_users u, payments p where u.user_id=p.user_id").to_a
        b.each { |line| y = line['contact'] }
      RUBY
      known = Set.new(%w[member_contacts big_users payments contact])

      expect(pairs(of(source, 'key_read', known: known)))
        .to contain_exactly(%w[contact member_contacts], ['contact', ''])
    end

    it 'gives a variable key on a result row a table as well' do
      source = <<~RUBY
        res = ActiveRecord::Base.connection.select_all("select * from member_contacts").to_a
        res.each { |line| x = line[field] }
      RUBY

      expect(pairs(of(source, 'key_dynamic', known: Set.new(%w[member_contacts]))))
        .to eq([['[]', 'member_contacts']])
    end

    it 'does not count a write into one own hash as a use of a column' do
      source = %q(result['member_photo'] = 1)

      expect(of(source, 'key_read', known: Set.new(%w[member_photo]))).to be_empty
    end

    it 'counts a variable key as a blind spot only on a result row' do
      source = %q(row = select_all(sql).to_a.first; x = row[field]; y = ids[i])
      found = of(source, 'key_dynamic', known: Set.new(%w[member_messenger]))

      expect(found.map { |ref| ref.detail[:on] }).to eq(['row'])
    end

    # The filter that removed a twelvefold overstatement: `Dir[glob]`, `ids[i]`,
    # `@countries[code]` are ordinary array accesses rather than column reads.
    # While the receiver went unchecked there were 7,906 of those out of 7,906.
    it 'does not count an array access as a blind spot over columns' do
      source = %q(a = Dir[pattern]; b = ids[i]; c = palette[index % palette.size])

      expect(of(source, 'key_dynamic')).to be_empty
    end

    # A loop over a field list is not a blind spot: the columns are known, they
    # only have to be bound to the block parameter. The most common form is the
    # list right inside the loop.
    it 'yields a read of every column of a list the loop walks' do
      source = %q(['show_in_catalogue','sex'].each { |par| member_info[par] })
      options = { known: Set.new(%w[show_in_catalogue sex]) }

      expect(of(source, 'key_read', **options).map(&:token))
        .to contain_exactly('show_in_catalogue', 'sex')
      expect(of(source, 'key_dynamic', **options)).to be_empty
    end

    it 'does not count a loop over words that are not columns as reads' do
      source = %q(['alpha','beta'].each { |par| member_info[par] })

      expect(of(source, 'key_read', known: Set.new(%w[sex]))).to be_empty
    end

    # The most valuable case for the question "which fields we do not use": the
    # column name is assembled at runtime, and as a word it does NOT exist in the
    # tree. Eleven columns of a `g*` series looked unused for exactly that
    # reason.
    it 'calls a hole in a column-name position the position "column"' do
      source = %q(or_ar << "#{make_goal(g)} in (#{list.join(',')})")
      found = of(source, 'sql_hole')

      expect(found.map { |ref| [ref.token, ref.owner] })
        .to include(['make_goal', 'column'], %w[list in_list])
    end

    it 'records an assembled name as a pattern a column of a series can be recognised by' do
      source = %q(x = @info["language#{num}_2"])

      expect(of(source, 'name_pattern').map(&:token)).to include('language$1_2')
    end

    # Three omissions found by the owner on the question "these fields ought to
    # be used". Each led in one direction — the column was listed as unused
    # while it is read.
    it 'reads the columns of a create table as select — such a query started with a drop' do
      source = %(Xdm.execute("drop table if exists t;\ncreate table t as select a.opt3_6 from big_users_live a"))

      expect(pairs(of(source, 'pg_column', known: Set.new(%w[opt3_6 big_users_live]))))
        .to include(%w[opt3_6 big_users_live])
    end

    it 'records a column inside a string expression with no interpolation by name' do
      source = %q(cond = "paid_until-paid_from<'32 days'::interval")
      options = { known: Set.new(%w[paid_until paid_from]) }

      expect(of(source, 'pg_column_expr', **options).map(&:token))
        .to contain_exactly('paid_until', 'paid_from')
    end

    # Without this condition the field list itself parsed as `select a,b,c` and
    # declared every column of the list used — that is, exactly what we moved
    # away from.
    it 'does not treat a field list as a string expression: it holds no operator' do
      source = %q(FIELDS = 'user_id,username,member_photo')

      expect(of(source, 'pg_column_expr', known: Set.new(%w[user_id username member_photo]))).to be_empty
    end

    # The parse of string expressions is memoised for the process (a full pass is
    # otherwise a quarter slower). The memo must depend on the set of known
    # names: with another set the same text gives another answer.
    it 'does not carry an expression-parse memo over to another set of names' do
      source = %q(cond = "paid_until-paid_from<'32 days'::interval")

      expect(of(source, 'pg_column_expr', known: Set.new(%w[paid_until paid_from])).size).to eq(2)
      expect(of(source, 'pg_column_expr', known: Set.new(%w[nothing]))).to be_empty
      expect(of(source, 'pg_column_expr', known: Set.new(%w[paid_until paid_from])).size).to eq(2)
    end

    it 'takes a value by key in a template the same way as in Ruby' do
      source = %(<div><%= user['blocked_token'] %></div>)
      refs = described_class.new('app/views/probe/_card.erb', source,
                                 known: Set.new(%w[blocked_token])).scan

      expect(refs.select { |ref| ref.kind == 'key_read' }.map(&:token)).to eq(['blocked_token'])
    end

    # "The column is named in the selection" and "rows are filtered by the
    # column" are different statements, and for the answer "is the field used"
    # the second one decides: an output list usually enumerates every column of
    # the table at once.
    it 'records a column in a condition and in an ordering as its own kind' do
      source = %q(Xdm.execute("select user_id, sex from big_users where member_age > 20 order by sex"))
      options = { known: Set.new(%w[big_users user_id sex member_age]) }

      expect(pairs(of(source, 'pg_column_filter', **options)))
        .to contain_exactly(%w[member_age big_users], %w[sex big_users])
      expect(of(source, 'pg_column_filter', **options).map(&:token)).not_to include('user_id')
    end

    # Environment keys: three classes, and without them the report "the key is
    # missing from the environment" would be a list of a hundred and thirty-eight
    # lines where a real hole lies next to an ordinary setting. The values are
    # read nowhere — only the names.
    it 'records the environment key name and, separately, whether there is a fallback' do
      source = <<~'RUBY'
        a = ENV['REQUIRED_URL']
        b = ENV.fetch('WITH_FETCH', 'x')
        c = ENV['WITH_OR'] || 'y'
      RUBY

      expect(of(source, 'env_key').map(&:token)).to contain_exactly('REQUIRED_URL', 'WITH_FETCH', 'WITH_OR')
      expect(of(source, 'env_default').map(&:token)).to contain_exactly('WITH_FETCH', 'WITH_OR')
    end

    it 'marks a read inside a condition as a FLAG: an empty value is legitimate there' do
      source = <<~'RUBY'
        puts 'on' if ENV['FLAG_A']
        puts 'on' unless ENV['FLAG_B'].to_i.zero?
      RUBY

      expect(of(source, 'env_flag').map(&:token)).to contain_exactly('FLAG_A', 'FLAG_B')
    end

    it 'does not count a key assembled at runtime as a name' do
      source = %q(x = ENV[key]; y = ENV["PREFIX_#{suffix}"])

      expect(of(source, 'env_key')).to be_empty
    end

    # A relative key (`t('.title')`) is never found in the store without being
    # resolved by place: a leading dot means nothing on its own.
    it 'resolves a relative translation key by the template path' do
      refs = described_class.new('app/views/users/_form.html.erb', %q(<%= t('.title') %>), known: Set.new).scan

      expect(refs.select { |ref| ref.kind == 'i18n_key' }.map(&:token)).to eq(['users.form.title'])
    end

    it 'resolves a relative key in a controller by the class and the action' do
      source = <<~'RUBY'
        class UsersController
          def show
            t('.saved')
          end
        end
      RUBY

      expect(of(source, 'i18n_key', path: 'app/controllers/users_controller.rb').map(&:token))
        .to eq(['users.show.saved'])
    end

    it 'records an assembled translation key as a pattern rather than as a name' do
      source = %q(x = t("contest.c#{num}"))

      expect(of(source, 'i18n_key')).to be_empty
      expect(of(source, 'i18n_dynamic').map(&:token)).to eq(['contest.c$1'])
    end

    it 'records a variable that had a query assigned to it together with the value' do
      source = <<~'RUBY'
        class Probe
          def pick
            sql = 'select id from big_users'
            sql << " where id in (#{ids.join(',')})"
          end
        end
      RUBY
      found = of(source, 'assign').first

      expect([found.token, found.owner]).to eq(['sql', 'Probe#pick'])
      expect(found.detail[:sql]).to be(true)
      expect(found.detail[:more]).to include('where id in ($1)')
    end
  end
end
