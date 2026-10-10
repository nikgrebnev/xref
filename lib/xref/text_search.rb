# frozen_string_literal: true

require 'open3'
require 'shellwords'

module Xref
  # Searching the TEXT of the tree — as a wrapper, not as an index of our own.
  #
  # The decision was made deliberately, against the temptation. The temptation
  # is a table of lines (55 MB of code, 71 MB with the documentation) plus a
  # trigram search: then text search would be "ours". But a second index would
  # age separately from the first, would need its own catch-up and its own
  # freshness check — precisely the disease this tool cures. A wrapper is fresh
  # by construction, needs no maintenance, and finds what a human's hands find.
  #
  # What the tool adds to the hits is exactly what grep cannot know: how the
  # file is reachable, which tables it touches, who calls it and how many blind
  # spots it contains. "Instead of grep" does not mean "faster than grep", it
  # means "grep plus meaning".
  #
  # Which engine. `rg` is orders of magnitude faster: 271 patterns over 196 MB
  # of tree take 0.9 s against 36 s for `git grep` (measured 2026-10-08). But it
  # may be absent, and an answer is still owed, so `git grep` is a fallback
  # rather than an error — and the report says which one it used: the fallback
  # has a different price, and a human should know why the answer took a while.
  module TextSearch
    Hit = Struct.new(:path, :line, :text, keyword_init: true)

    # Files there is no point searching under any question.
    IGNORED = %r{\A(vendor/|node_modules/|public/|tmp/|log/|\.git/)}
    MAX_HITS = 4000
    TIMEOUT = 120

    class << self
      # [command, name] — what the search runs with. Order: an explicit setting
      # (XREF_RG or the config), `rg` from PATH, `rg` from the version manager,
      # `git grep`.
      def tool
        @tool ||= detect_tool
      end

      def reset!
        @tool = nil
      end

      def ripgrep?
        tool[1] == 'rg'
      end

      # Lines of the tree that matched the pattern.
      #
      # `fixed` — search as TEXT rather than as an expression: Ruby method names
      # can be `[]`, `part?`, `activate!`, and as an expression they either do
      # not parse or mean something else.
      # `word` — whole words only (`-w`). Needed wherever the pattern is a NAME:
      # without it `make_param` matches inside `make_param_list`, and the number
      # of candidate lines grows by orders of magnitude (measured: 100,000
      # against 2,000).
      def lines(pattern, root: Xref.root, fixed: false, ignore_case: false,
                word: false, globs: [], limit: MAX_HITS)
        command = tool.first + search_arguments(pattern, fixed: fixed, ignore_case: ignore_case,
                                                        word: word, globs: globs, limit: limit)
        out, _err, status = run(command, root)
        # Neither `rg` nor `git grep` treats "nothing found" as an error above
        # exit code one. Anything above that is a real failure, and staying
        # silent about it is not allowed: an empty answer reads as "this is not
        # in the tree".
        raise Error, "поиск по тексту не удался (#{tool[1]}, код #{status.exitstatus})" if status.exitstatus.to_i > 1

        parse(out, limit: limit)
      end

      # MATCHES ONLY, without lines and paths (`rg -o`). Needed where the
      # question is not "in which files" but "which names exist in the tree at
      # all": route helpers, URLs written as strings. A Ruby pass over 196 MB
      # costs 11 and 6 seconds; `rg` returns the same in a fraction of one.
      #
      # Returns nil when `rg` is unavailable: `git grep` has its own `-o`, but
      # its behaviour differs across versions, and substituting it for an honest
      # full pass risks a silent divergence. No `rg` — the caller does the full
      # pass.
      MAX_MATCHES = 2_000_000

      def matches(pattern, root: Xref.root, limit: MAX_MATCHES, globs: [])
        return nil unless ripgrep?

        command = tool.first + ['--only-matching', '--no-filename', '--no-line-number',
                                '--no-heading', '--no-messages', '--hidden', '--glob', '!.git/*']
        globs.each { |glob| command.push('--glob', glob) }
        command.push('--regexp', pattern.to_s, '.')
        out, _err, status = run(command, root)
        return nil if status.exitstatus.to_i > 1

        found = []
        Xref.utf8(out).each_line do |row|
          found << row.chomp
          break if found.size >= limit
        end
        found
      end

      def parse(out, limit: MAX_HITS)
        hits = []
        # SEARCH OUTPUT IS ALWAYS UTF-8, WHATEVER THE SHELL'S LOCALE IS.
        #
        # With no locale (`LANG` unset — which is how a non-interactive shell
        # and a script run) Ruby assumes the external encoding is US-ASCII, and
        # the first non-Latin letter in a matched line brings down `split` with
        # "invalid byte sequence in US-ASCII". The report is then not empty but
        # ABSENT: the whole command dies, which reads as "the tool is broken",
        # after which the human goes back to grep.
        #
        # `scrub` is for genuine garbage in a file: better to show a line with
        # one byte replaced than to lose the hit entirely.
        out.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line do |row|
          path, line, text = row.chomp.split(':', 3)
          next if path.nil? || line.to_i.zero? || text.nil?

          # `rg` prints paths starting with "./", `git grep` without it. Bring
          # them to one form: further down this path is joined to the index by
          # equality.
          path = path.delete_prefix('./')
          next if path.match?(IGNORED)

          hits << Hit.new(path: path, line: line.to_i, text: text)
          break if hits.size >= limit
        end
        hits
      end

      private

      def search_arguments(pattern, fixed:, ignore_case:, globs:, limit:, word: false)
        if ripgrep?
          # `--hidden`, because `.claude/*.md` is tracked by git while `rg` by
          # default does not enter dot-directories: without it the answers of
          # `rg` and `git grep` differed by 5 hits out of 67, and differed
          # SILENTLY.
          args = ['--no-heading', '--line-number', '--no-messages', '--hidden',
                  '--glob', '!.git/*', '--max-count', limit.to_s]
          args << '--fixed-strings' if fixed
          args << '--ignore-case' if ignore_case
          args << '--word-regexp' if word
          globs.each { |glob| args.push('--glob', glob) }
          # The path argument is mandatory, and that is not a formality: without
          # it `rg`, when stdin is not a terminal, reads STANDARD INPUT, quietly
          # finds nothing and exits with code 1 — that is, "this is not in the
          # tree". By hand the same command answered with 1,282 lines; from a
          # program, with zero.
          args.push('--regexp', pattern.to_s, '.')
        else
          # `git grep` looks only at tracked files — for our questions that is
          # correct and even useful: junk in the working directory stays out of
          # the answer.
          args = %w[-n -I --no-color]
          args << '-F' if fixed
          args << '-i' if ignore_case
          args << '-w' if word
          args.push('-e', pattern.to_s)
          # Negation in a pathspec is written differently from `rg`:
          # `!path` → `:!path`.
          args.push('--', *globs.map { |glob| glob.start_with?('!') ? ":!#{glob.delete_prefix('!')}" : glob }) if globs.any?
          args
        end
      end

      def run(command, root)
        Open3.capture3(*command, chdir: root.to_s)
      rescue StandardError => e
        raise Error, "поиск по тексту не запустился: #{e.message}"
      end

      def detect_tool
        explicit = ENV['XREF_RG'].presence || Xref.config[:text_search]
        return [Shellwords.split(explicit.to_s), 'rg'] if explicit.present?

        return [['rg'], 'rg'] if works?(['rg', '--version'])

        version = installed_ripgrep
        if version
          command = ['mise', 'exec', "ripgrep@#{version}", '--', 'rg']
          return [command, 'rg'] if works?(command + ['--version'])
        end

        [%w[git grep], 'git grep']
      end

      # The version manager may keep ripgrep installed but with no version
      # selected, and then the shim fails — so the version is asked for and
      # substituted explicitly.
      def installed_ripgrep
        out, _err, status = Open3.capture3('mise', 'ls', '--installed', 'ripgrep')
        return nil unless status.success?

        out.lines.first.to_s.split[1]
      rescue StandardError
        nil
      end

      def works?(command)
        _out, _err, status = Open3.capture3(*command)
        status.success?
      rescue StandardError
        false
      end
    end
  end
end
