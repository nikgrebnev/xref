# frozen_string_literal: true

module Xref
  # Parsing shell scripts.
  #
  # Why. Our `.sh` files hold what production depends on: deploys, collection,
  # cleanup, sweeps across nodes. They read environment keys, they carry
  # database queries, they name nodes and services — and the index knew none of
  # those facts, because `.sh` was not in the walk at all. The question "who
  # else reads this key" had an answer only for Ruby, while scripts read keys too.
  #
  # The parse deliberately does NOT pretend to be a shell parser: we have none,
  # and writing one for these questions is not worth it. What is taken are the
  # places where the markup is unambiguous: a variable expansion, an assignment,
  # a heredoc, a call to a known command. Everything ambiguous is not recorded —
  # better to stay silent than to guess.
  module Shell
    # `$VAR`, `${VAR}`, `${VAR:-default}`. Positional (`$1`) and special (`$?`)
    # do not count: those are not environment keys.
    VARIABLE = /\$\{(?<braced>[A-Za-z_][A-Za-z0-9_]*)(?<modifier>[:\-+?=][^}]*)?\}|\$(?<bare>[A-Za-z_][A-Za-z0-9_]*)/
    # An assignment at the start of a line, with or without `export`, including
    # `VAR=${X:-1}`.
    ASSIGN = /^\s*(?:export\s+|readonly\s+|local\s+|declare\s+-\w+\s+)?(?<name>[A-Za-z_][A-Za-z0-9_]*)=/
    # A name also receives a value WITHOUT an equals sign: in a loop, when
    # reading a line, when declaring a local. Without these three forms the
    # count of "environment keys" filled up with `h`, `relay`, `target`,
    # `attempt` — loop variables, of which a tree holds more than real keys.
    BOUND = [
      /^\s*for\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+in\b/,
      /\bread\s+(?:-\w+\s+)*(?<name>[A-Za-z_][A-Za-z0-9_]*)/,
      # `local` is caught ANYWHERE in the line, not only at its start: a
      # function body is often written on one line
      # (`f() { local tmp=1; echo $tmp; }`), and anchored to the start `tmp`
      # ended up among environment keys — an error in the dangerous direction.
      /(?:\A|[;{(&|]|\bthen\b|\bdo\b)\s*local\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\b/,
      /^\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{/
    ].freeze
    # `<<EOF`, `<<-EOF`, `<<'SQL'`, `<<"SQL"`.
    HEREDOC = /<<[-~]?\s*(?<quote>['"]?)(?<tag>[A-Za-z_][A-Za-z0-9_]*)\k<quote>/
    # The commands people ask about. The rest do not enter the index: "echo was
    # called" answers nothing.
    COMMANDS = %w[
      psql pg_dump pg_restore mysql clickhouse-client
      docker docker-compose kubectl systemctl service
      ssh scp rsync curl wget
      git mise bundle rails rake
      nebula-cert fstrim mkfs cron crontab
    ].freeze
    # A quote before the command is a hint rather than an obstacle:
    # `ssh node1 'docker ps'` runs `docker` ON THE NODE, and that is exactly
    # what needs to be visible.
    COMMAND_LINE = %r{(?:\A|[;&|('"]|\$\()\s*(?<command>[a-z][a-z0-9_.-]*)\b}
    # Dangerous: recursive and forced removal. In this tree such places were
    # worth knowing by name — the report says them out loud.
    DANGEROUS = /\brm\s+(?:-\w+\s+)*-\w*[rf]|\bdd\s+if=|\bmkfs\b|\btruncate\s+-s\s*0|\bchmod\s+777\b/

    Element = Struct.new(:kind, :text, :line, :extra, keyword_init: true)

    class << self
      # => [Element, …]
      def elements(source)
        out = []
        heredocs = collect_heredocs(source, out)

        source.each_line.with_index(1) do |row, line|
          next if heredocs.include?(line)
          # A comment is not code. A hash inside a quoted string happens, but a
          # line that STARTS with a hash is always a comment.
          next if row.match?(/\A\s*#/)

          if (match = row.match(ASSIGN))
            out << Element.new(kind: 'assign', text: match[:name], line: line, extra: {})
          end
          BOUND.each do |regexp|
            bound = row.match(regexp)
            next if bound.nil?

            # `bound`, not `assign`: an assignment with an equals sign may read
            # the environment (`VAR=${VAR:-1}`), a loop name never does.
            out << Element.new(kind: 'bound', text: bound[:name], line: line, extra: {})
          end
          scan_variables(row, line, out)
          scan_commands(row, line, out)
          out << Element.new(kind: 'dangerous', text: row.strip[0, 120], line: line, extra: {}) if row.match?(DANGEROUS)
        end
        out.sort_by!(&:line)
        out
      end

      private

      # The body of a heredoc is usually a query or a configuration file, and
      # parsing it as shell lines is wrong. It is collected whole and handed
      # back as its own element.
      def collect_heredocs(source, out)
        inside = Set.new
        open_tag = nil
        open_at = nil
        body = []

        source.each_line.with_index(1) do |row, line|
          if open_tag
            inside << line
            if row.strip == open_tag
              out << Element.new(kind: 'heredoc', text: body.join, line: open_at, extra: { tag: open_tag })
              open_tag = nil
            else
              body << row
            end
            next
          end

          match = row.match(HEREDOC)
          next if match.nil?

          open_tag = match[:tag]
          open_at = line
          body = []
          inside << line
        end
        out << Element.new(kind: 'heredoc', text: body.join, line: open_at, extra: { tag: open_tag, unclosed: true }) if open_tag
        inside
      end

      def scan_variables(row, line, out)
        row.to_enum(:scan, VARIABLE).each do
          match = Regexp.last_match
          name = match[:braced] || match[:bare]
          next if name.nil?

          out << Element.new(kind: 'variable', text: name, line: line,
                             extra: { default: match[:modifier].to_s.start_with?(':-', '-') }.compact)
        end
      end

      def scan_commands(row, line, out)
        row.to_enum(:scan, COMMAND_LINE).each do
          match = Regexp.last_match
          command = match[:command]
          next unless COMMANDS.include?(command)

          out << Element.new(kind: 'command', text: command, line: line,
                             extra: { line_text: row.strip[0, 160] })
        end
      end
    end
  end
end
