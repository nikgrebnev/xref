# frozen_string_literal: true

module Xref
  # Parsing markdown into parts, with line numbers.
  #
  # Why documentation belongs in the index. Of 23,337 tracked files 12,243 are
  # `.md`, and until this layer existed the index knew NOTHING about them: every
  # question — "where is this written down", "where does this link lead", "has
  # this document gone stale" — went to grep. Yet documentation is as much a
  # source of statements about the tree as code is, and its statements age
  # silently.
  #
  # This is a parse, not "text line by line": headings give sections, links give
  # edges (and broken links give a finding), and code blocks are parsed by THE
  # SAME parsers as files rather than by eye. A query inside a document that
  # does not parse is an example nobody ever ran.
  #
  # What is deliberately NOT done here: words of prose do not enter the index. A
  # name from the database is recorded only where it is named ON PURPOSE — in
  # backticks or in a code block. Otherwise 157 MB of documents would drown the
  # answers in matches of the form "in the table below".
  module Markdown
    FENCE = /^(?<indent>[ \t]*)(?<mark>```+|~~~+)[ \t]*(?<lang>[\w+-]*)[ \t]*$/
    HEADING = /^(?<hashes>\#{1,6})\s+(?<text>.+?)\s*\#*$/
    # `[name](target)` — the target has no spaces, or is wrapped in angle brackets.
    LINK = /\[(?<text>[^\]\n]*)\]\((?<target><[^>\n]*>|[^)\s]+)(?:\s+"[^"\n]*")?\)/
    # An internal link in wiki form: that is how the memory notes are connected.
    WIKI = /\[\[(?<target>[^\]\n|]+)(?:\|[^\]\n]*)?\]\]/
    # Backticks: one or more, with no newline inside.
    SPAN = /(?<ticks>`+)(?<code>[^`\n](?:[^\n]*?[^`\n])?)\k<ticks>/
    # Looks like a path in the tree: has a slash or an extension, has no spaces.
    PATH_LIKE = %r{\A[a-zA-Z0-9_./~-]+\z}
    PATH_MARK = %r{/|\.(rb|erb|rake|js|mjs|sql|yml|yaml|json|md|sh|conf|ru)\z}

    Element = Struct.new(:kind, :text, :line, :extra, keyword_init: true)

    class << self
      # => [Element, …] in order of appearance.
      #
      # Code blocks are cut out FIRST, and that is not an optimisation: inside a
      # block `#` is a comment of the language rather than a heading, and
      # `[a](b)` is a call rather than a link. Without this the parse found
      # headings in SQL and links in Ruby.
      def elements(source)
        out = []
        in_code = fenced_lines(source, out)

        source.each_line.with_index(1) do |row, line|
          next if in_code.include?(line)

          if (match = row.match(HEADING))
            out << Element.new(kind: 'heading', text: match[:text].to_s.strip,
                               line: line, extra: { level: match[:hashes].length })
          end
          scan_links(row, line, out)
          scan_spans(row, line, out)
        end
        out.sort_by!(&:line)
        out
      end

      private

      # Block boundaries: an opening mark is closed by one of the same length or
      # longer. An unclosed block runs to the end of the file — that is how the
      # renderer reads it too, and counting otherwise means disagreeing with
      # what a human sees.
      def fenced_lines(source, out)
        inside = Set.new
        open_at = nil
        open_mark = nil
        open_lang = nil
        body = []

        source.each_line.with_index(1) do |row, line|
          match = row.match(FENCE)
          if open_at.nil?
            next if match.nil?

            open_at = line
            open_mark = match[:mark]
            open_lang = match[:lang].to_s.downcase
            body = []
            inside << line
          else
            inside << line
            if match && match[:mark].length >= open_mark.length && match[:lang].to_s.empty?
              out << Element.new(kind: 'code', text: body.join, line: open_at,
                                 extra: { lang: open_lang, lines: body.size })
              open_at = nil
            else
              body << row
            end
          end
        end
        if open_at
          out << Element.new(kind: 'code', text: body.join, line: open_at,
                             extra: { lang: open_lang, lines: body.size, unclosed: true })
        end
        inside
      end

      def scan_links(row, line, out)
        row.to_enum(:scan, LINK).each do
          match = Regexp.last_match
          target = match[:target].to_s.delete_prefix('<').delete_suffix('>')
          out << Element.new(kind: 'link', text: target, line: line,
                             extra: { label: match[:text].to_s[0, 80] })
        end
        row.to_enum(:scan, WIKI).each do
          match = Regexp.last_match
          out << Element.new(kind: 'link', text: match[:target].to_s.strip, line: line,
                             extra: { wiki: true })
        end
      end

      def scan_spans(row, line, out)
        row.to_enum(:scan, SPAN).each do
          match = Regexp.last_match
          code = match[:code].to_s.strip
          next if code.empty? || code.length > 200

          out << Element.new(kind: 'span', text: code, line: line, extra: {})
        end
      end
    end

    # Does this look like a path in the tree? Kept apart from the parse: both
    # links and backticks ask the same question.
    def self.path_like?(text)
      return false unless text.match?(PATH_LIKE) && text.match?(PATH_MARK)
      return false if text.start_with?('http')
      # `app/views/theme_desktop/...` means "and so on down the directory",
      # not a path.
      return false if text.include?('...')
      # A leading tilde is a home directory rather than a path of the tree; and
      # it also used to crash the parse: `File.expand_path` on `~name.js` raises
      # "user doesn't exist".
      return false if text.start_with?('~')
      # `.rb` on its own is not a path but an extension inside text about
      # extensions.
      return false if File.basename(text).start_with?('.') && !text.include?('/')

      text.include?('/') || File.basename(text, '.*').length >= 2
    end

    # Is the path anchored at the ROOT of the tree? This decides whether a
    # missing file counts as a finding: documentation is full of illustrative
    # examples (`user_profile.rb`, `app/models/foo.rb` in a guide, deliberately
    # with made-up names), and calling those broken links drowns the real
    # findings in invented ones. A real reference to the tree always starts with
    # a known directory.
    ROOTED = %r{\A(app|lib|spec|config|db|doc|script|scripts|bin|public|vendor|\.claude)/}
    def self.rooted?(text)
      text.match?(ROOTED)
    end
  end
end
