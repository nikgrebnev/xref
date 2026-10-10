# frozen_string_literal: true

require 'erb'
require 'yaml'
# Nothing else pulls in `Pathname` when Rails is absent, and `home`/`root`
# return one.
require 'pathname'

# A cross-reference index of the code and of the live databases.
#
# The job: answer "what does this edit touch" with one query instead of twenty
# greps — which tables and columns exist in each source, and then (step two)
# which places in the code touch them.
#
# The schema is stored PER SOURCE rather than as one pile: two production
# databases drifted apart by hundreds of tables, and "the schema" in the
# singular is a fiction that lies silently.
#
# Entry points: rake xref:init / xref:schema / xref:drift.
module Xref
  class Error < StandardError; end

  CONFIG_PATH = 'config/xref.yml'

  # THE HABITS OF THIS TREE — the part every project has its own version of.
  #
  # These lists are not a matter of taste, they are knowledge about one tree:
  # which methods fetch a result row here, how a variable holding such a row is
  # conventionally named, which wrappers of the columnar store take the TABLE as
  # their first argument. Baked into the parser they make the tool
  # unportable: in a second project that is how the caption "shared legacy
  # across 18 languages" came to state an untruth about a two-language tree.
  #
  # The defaults live in code so the tool works in a project with no
  # configuration at all; `config/xref.yml` extends or replaces them.
  IDIOM_DEFAULTS = {
    row_source: %w[select_all select_one select_rows select_values find_by_sql],
    row_names: %w[row line rec info entry item],
    table_first: [],
    guess_stoplist: %w[
      set now the only lateral values select where group order limit offset
      generate_series unnest jsonb_array_elements jsonb_array_elements_text
      jsonb_each json_array_elements regexp_split_to_table string_to_table
      slice cohort dual
    ],
    locale_dirs: %w[config/locales],
    # WHERE THE JAVASCRIPT STARTS. A build root is an entry point rather than a
    # dead file: nothing imports it by construction, the bundler starts from it.
    # The engine knows the roots named in a bundler config as FACTS (`js_entry`),
    # and this list is for the trees whose config it cannot read — a layout
    # pattern, not a name. Baked in as `app/javascript/packs/%` it made the whole
    # front end of a project on esbuild unreachable: nineteen files, eleven
    # import edges, and ZERO reachable from an entry point. Reported from that
    # project on 2026-10-10.
    js_entry_paths: %w[app/javascript/packs/%],
    # The service that runs WebSocket channels. Without it the code reachable
    # only from a channel lies outside the graph.
    channel_service_units: %w[anycable-rpc],
    # The languages a key MUST exist in. Everything else is a translation that
    # may be missing without a defect; these are the ones the fallbacks hide. A
    # tree with another pair says so here instead of patching the report.
    main_locales: %w[en],
    # The constant that holds the cron schedule, and the key inside an entry that
    # says WHERE the job runs. Both are app-specific: the engine knew one
    # particular application's names by heart, which is both a leak and the
    # unportability of III.4.
    cron_registry: nil,
    cron_place_key: 'place',
    # The wrapper that makes a thrift protocol for the columnar store. Absent —
    # the library's own binary protocol is used.
    column_store_protocol: nil,
    # Which column the "recent cohort" is counted by. The first one found on the
    # table wins; guessing by type is not possible, a table may hold five dates.
    recency_columns: %w[created_at inserted_at added_at created inserttime],
    prose_is_non_ascii: true,
    standard_env: %w[
      PATH HOME PWD SHELL TERM USER LANG LC_ALL TZ TMPDIR HOSTNAME
      RAILS_ENV RACK_ENV RAILS_ROOT BUNDLE_GEMFILE GEM_HOME GEM_PATH RUBYOPT
    ]
  }.freeze

  class << self
    # EVERYTHING THAT CAME FROM OUTSIDE IS RE-TAGGED UTF-8 AND SCRUBBED.
    #
    # Bytes from an external command, from ENV and from a file arrive tagged
    # with the LOCALE's encoding. Without `LANG` (a non-interactive shell, cron,
    # a script) that is US-ASCII, and the first non-Latin letter brings down
    # `split`, `match?` or `format` — "invalid byte sequence in US-ASCII",
    # "incompatible character encodings". What fails is not one finding but the
    # whole command: no report is printed at all, and that reads as "the tool is
    # broken".
    #
    # An application covers this in `config/environment.rb`
    # (`Encoding.default_external = Encoding::UTF_8`), but index queries do NOT
    # load Rails, so they never get that setting. `force_utf8!` applies it in
    # `bin/xref-run`; this function is the second layer, for the places where
    # the bytes may genuinely be broken: changing the default encoding fixes the
    # LABEL, not the content, and a file with real garbage still kills the parse.
    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')
    end

    # Applied by the entry point that runs without Rails. Repeats what an
    # application does in config/environment.rb.
    def force_utf8!
      Encoding.default_external = Encoding::UTF_8
      Encoding.default_internal = nil
    end

    # An SQL array literal out of configured values. The views are built when the
    # file loads, so this cannot lean on a database connection; the values come
    # from the configuration and are quoted rather than glued in — a pattern with
    # an apostrophe would otherwise end the string and the view would be created
    # from whatever came after it.
    def sql_text_array(values)
      list = Array(values).map { |v| "'#{v.to_s.gsub("'", "''")}'" }.join(', ')
      list.empty? ? 'array[]::text[]' : "array[#{list}]::text[]"
    end

    def idioms
      @idioms ||= begin
        given = config[:idioms] || {}
        # A HABIT WRITTEN AT THE TOP LEVEL IS A SETTING WITH NO EFFECT, and it
        # looks exactly like a setting that works. One project kept
        # `locale_dirs:` at the top of its configuration, the engine read
        # `idioms.locale_dirs`, and the translations were collected from the
        # default directory while the file said otherwise. Said out loud once,
        # because the alternative is a report that counts by other rules and
        # looks fresh.
        stray = (config.keys & IDIOM_DEFAULTS.keys) - [:idioms]
        unless stray.empty?
          warn "xref: #{stray.join(', ')} в конфигурации стоят СНАРУЖИ idioms: — " \
               'эти значения не читаются; перенесите их под `idioms:`'
        end
        IDIOM_DEFAULTS.to_h do |key, default|
          value = given[key]
          [key, value.nil? ? default : value]
        end
      end
    end

    # A digest of the habits: they are an INPUT of the parse, and changing a
    # list changes the result while every file stays the same — exactly like a
    # schema change.
    def idiom_digest
      require 'digest'

      Digest::SHA1.hexdigest(idioms.sort.map { |key, value| "#{key}=#{Array(value).join(',')}" }.join('|'))
    end

    def config
      @config ||= begin
        raw = ERB.new(File.read(home.join(CONFIG_PATH))).result
        YAML.safe_load(raw, aliases: true).deep_symbolize_keys
      end
    end

    # Drop the memoized config (needed only in tests and in a console).
    def reload_config!
      @config = nil
      @idioms = nil
      @root = nil
    end

    def sources
      config[:sources] || {}
    end

    def source(name)
      sources[name.to_sym] ||
        raise(Error, "неизвестный источник #{name.inspect}; в config/xref.yml есть: #{sources.keys.join(', ')}")
    end

    def store_url
      config[:store_url] or raise(Error, 'в config/xref.yml не задан store_url')
    end

    # TWO ROOTS, and they must not be confused.
    #
    # `home` is the directory of the TOOL ITSELF: `config/xref.yml` lives here,
    # so do its specs and its `Gemfile`, and writing here is allowed.
    #
    # `root` is the tree being indexed, and it is READ-ONLY: someone else's edit
    # or build may be running there at this very moment, and an analysis tool has
    # no business writing a file into it or committing anything.
    #
    # Inside an application the two coincide — the tool lives in the same tree.
    # Installed separately (its own directory, its own bundle) they differ, and
    # then the tree is named by `project_root` in the configuration. That is also
    # how the tool works where the project is not a Rails one at all: all it
    # needs is a directory and `git ls-files`.
    def home
      @home ||= Pathname.new(File.expand_path('..', __dir__))
    end

    def root
      @root ||= begin
        given = config[:project_root].to_s
        if !given.empty?
          path = Pathname.new(given)
          path.absolute? ? path : home.join(path)
        elsif defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root
        else
          Pathname.new(Dir.pwd)
        end
      end
    end

    def git_sha
      @git_sha ||= `git -C #{root} rev-parse --short HEAD 2>/dev/null`.strip.presence
    end
  end
end
