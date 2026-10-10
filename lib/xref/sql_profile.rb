# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'digest'

module Xref
  # Queries that actually RAN — from the database's own statistics (pg_profile).
  #
  # A second source of the same knowledge `Xref::SqlRuntime` takes from the
  # application logs, and it is better in exactly one respect, which happens to
  # be decisive: the WINDOW. A log lives for days and then rotates, while
  # pg_profile keeps `pg_stat_statements` snapshots as history — 336 snapshots
  # over eight days here, where the logs covered two. Anything rare (a weekly
  # cron, a monthly report) does not fall into a one-day window at all, and
  # widening that window with logs means hoarding logs the database already has.
  #
  # Three rules, and all three are the same as for the log collector.
  #
  # **Values never leave the node.** The text from `pg_stat_statements` already
  # has its literals replaced (`where id = $1`), but relying on that alone is
  # not allowed: some statements PostgreSQL does not parameterise. Normalisation
  # runs ON THE NODE, with the same set of rules as for logs.
  #
  # **Numbers inside names are left alone.** `events_log2`, `sessions_live3` are
  # the table names the whole exercise is about.
  #
  # **Only data statements are taken.** The statistics also hold `SAVEPOINT $1`
  # and `SET application_name=$1` — millions of calls from which nothing about
  # the tree can be learned.
  module SqlProfile
    CONNECT_TIMEOUT = 25
    SSH_TIMEOUT = 1800
    MAX_SKELETON = 1500
    DEFAULT_DAYS = 30

    # Normalisation expressed in SQL, on the node: strings → `'x'`, numbers
    # outside names → `1`, repetitions in lists collapsed, whitespace squeezed.
    NORMALIZE = <<~SQL.strip
      left(regexp_replace(
             regexp_replace(
               regexp_replace(
                 regexp_replace(l.query, '''[^'']*''', '''x''', 'g'),
               '([^A-Za-z0-9_$])[0-9][0-9.]*', '\\1 1', 'g'),
             '''x''( *, *''x'')+', '''x''', 'g'),
           '\\s+', ' ', 'g'), %<limit>d)
    SQL

    class << self
      # => [{ host:, day:, skeleton:, hits: }, …]
      def collect(name, cfg, days: DEFAULT_DAYS)
        source = Xref.source(name)
        out, err, status = Open3.capture3(
          'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
          source[:ssh_host].to_s, remote_script(source, cfg),
          stdin_data: query(cfg, days: days)
        )
        unless status.success?
          raise Error, "#{name}: pg_profile вернул #{status.exitstatus}: " \
                       "#{Xref.utf8(err).strip.lines.last(2).join(' ').strip}"
        end

        parse(out, host: cfg[:host].presence || 'pg_profile')
      end

      def parse(out, host:)
        Xref.utf8(out).lines.filter_map do |line|
          day, hits, skeleton = line.strip.split('|', 3)
          next if skeleton.blank? || hits.to_i.zero? || day.blank?

          # Cutting at a character splits a name in half and invents a table
          # (`big_users` → `big_`): cut at the last whitespace, by the rule from
          # SqlRuntime.
          { host: host.to_s, day: Date.parse(day),
            skeleton: Xref::SqlRuntime.trim_tail(skeleton.strip[0, MAX_SKELETON], MAX_SKELETON),
            hits: hits.to_i }
        rescue Date::Error
          next
        end
      end

      # The window the database remembers about itself: that is the window the
      # answer is about.
      def window_query(cfg)
        <<~SQL.squish
          select min(s.sample_time)::date || '|' || max(s.sample_time)::date || '|' || count(*)
          from profile.samples s
          join profile.servers v on v.server_id = s.server_id
                               and v.server_name = #{quote(cfg[:server_name] || 'local')}
        SQL
      end

      def query(cfg, days: DEFAULT_DAYS)
        <<~SQL
          with win as (
            select s.sample_id, s.server_id, s.sample_time::date as day
            from profile.samples s
            join profile.servers v on v.server_id = s.server_id
                                 and v.server_name = #{quote(cfg[:server_name] || 'local')}
            where s.sample_time >= current_date - #{days.to_i}
          ),
          app as (
            select distinct d.sample_id, d.datid
            from profile.sample_stat_database d
            where d.datname = #{quote(cfg[:app_database])}
          ),
          counted as (
            select w.day as day, sum(st.calls) as hits,
                   #{format(NORMALIZE, limit: MAX_SKELETON)} as skeleton
            from profile.sample_statements st
            join win w on w.sample_id = st.sample_id and w.server_id = st.server_id
            join app a on a.sample_id = st.sample_id and a.datid = st.datid
            join profile.stmt_list l on l.server_id = st.server_id and l.queryid_md5 = st.queryid_md5
            where l.query ~* '^[[:space:]]*(select|insert|update|delete|with)[[:space:]]'
            group by 1, 3
            having sum(st.calls) > 0
          )
          select day || '|' || hits || '|' || skeleton from counted;
        SQL
      end

      private

      # The container name in the configuration is a PATTERN: under an
      # orchestrator the name carries a task suffix and changes on every
      # restart. It is resolved on the far side.
      def remote_script(source, cfg)
        match = Shellwords.escape("^#{Regexp.escape(source[:container].to_s)}(\\.|$)")
        # `ON_ERROR_STOP=1` is not pedantry: without it psql exits with ZERO on a
        # query error, and an empty output reads as "there is nothing in the
        # statistics". Caught on the very first run: the grouping by position in
        # a concatenated string was wrong, and the report said "0 skeletons".
        psql = Shellwords.join(['psql', '-v', 'ON_ERROR_STOP=1',
                                '-U', (cfg[:user] || source[:user]).to_s,
                                '-d', (cfg[:database] || 'profile').to_s,
                                '-At', '-q', '-F', '|', '-f', '-'])
        <<~SH
          c=$(docker ps --format '{{.Names}}' | grep -E #{match} | head -1)
          if [ -z "$c" ]; then echo "контейнер по образцу #{source[:container]} не найден" >&2; exit 1; fi
          exec docker exec -i "$c" #{psql}
        SH
      end

      # Quoting for a literal that travels INTO A QUERY on a node. There is no
      # connection of ours to that database at all, so it is done by hand and
      # strictly: anything but letters, digits and underscores is refused.
      def quote(value)
        text = value.to_s
        raise Error, "недопустимое имя в настройке pg_profile: #{text.inspect}" unless text.match?(/\A[A-Za-z0-9_]+\z/)

        "'#{text}'"
      end
    end
  end
end
