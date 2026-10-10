# frozen_string_literal: true

module Xref
  # Stylesheets: what they declare and what they pull in.
  #
  # The layer was added on 2026-10-10 and did not exist before that: 43 of our
  # own files, 22 thousand lines, were invisible to the index — so the question
  # "which styles are not needed" had nothing to answer with.
  #
  # The parse is deliberately PARTIAL, and that is the main decision here.
  # Exactly three things are needed: which classes are declared, which files
  # include one another, and which classes the CSS itself mentions (`@apply`).
  # Property values, variables, mixins and media conditions are not parsed:
  # nobody asks questions about them, and parsing the cascade and specificity
  # means writing your own browser.
  #
  # Two SCSS traps, each of which produces a false answer in its own way:
  #
  #   * `&-big` inside `.btn` declares `.btn-big`, and that name appears
  #     nowhere in the file in full. Without assembling it the report calls
  #     `btn-big` "undeclared" where a rule does exist;
  #   * `@import 'partial'` refers to `_partial.scss` — a file name with an
  #     underscore that the reference itself does not carry.
  module Css
    Element = Struct.new(:kind, :name, :detail, :line, keyword_init: true)

    COMMENT = %r{/\*.*?\*/}m
    LINE_COMMENT = %r{(?<![:'"])//[^\n]*}
    IMPORT = /@(?:import|use)\s+(?:url\()?['"]?([^'")\s;]+)/
    APPLY = /@apply\s+([^;}]+)/
    CLASS_TOKEN = /\.(-?[A-Za-z_][A-Za-z0-9_-]*)/
    ID_TOKEN = /#(-?[A-Za-z_][A-Za-z0-9_-]*)/
    # `&-big`, `&__cell`, `&.active` — a continuation of the parent selector.
    AMPERSAND = /&([-_A-Za-z0-9]*)/
    # `@media`, `@supports` and `@keyframes` are not selectors themselves, but
    # their body holds ordinary selectors — so the nesting level is counted
    # while the name from the preamble is not taken.
    AT_RULE = /\A\s*@/

    class << self
      # => [Element(kind: 'class'|'id'|'import'|'apply', name:, line:)]
      def elements(source)
        text = source.to_s.gsub(COMMENT, ' ').gsub(LINE_COMMENT, ' ')
        out = []
        stack = []
        line = 1

        text.each_line do |row|
          row.scan(IMPORT) { out << Element.new(kind: 'import', name: Regexp.last_match(1), line: line) }
          row.scan(APPLY) do
            Regexp.last_match(1).split(/\s+/).reject(&:empty?).each do |name|
              out << Element.new(kind: 'apply', name: name.delete_prefix('.'), line: line)
            end
          end

          # The selector preamble is everything before `{`. Closing braces pop a
          # level: without that the SCSS nesting would be counted wrongly and
          # `&` would attach to the wrong parent.
          row.scan(/[^{}]*[{}]/) do |chunk|
            piece = chunk[0..-2].to_s
            if chunk.end_with?('{')
              names = piece.match?(AT_RULE) ? [] : selector_names(piece, stack.last)
              stack.push(names.empty? ? (stack.last || []) : names)
              names.each { |name| out << Element.new(kind: 'class', name: name, line: line) }
              ids_of(piece).each { |name| out << Element.new(kind: 'id', name: name, line: line) }
            else
              stack.pop
            end
          end
          line += 1
        end
        out
      end

      # Class names of a selector, resolving `&` against the parent.
      def selector_names(selector, parent)
        names = []
        selector.to_s.split(',').each do |part|
          part = part.strip
          next if part.empty?

          if part.start_with?('&')
            suffix = part[/\A&([-_A-Za-z0-9]*)/, 1].to_s
            Array(parent).each do |base|
              names << (suffix.empty? ? base : "#{base}#{suffix}")
            end
            # `&.active` and `& .inner` declare their own classes as well.
            names.concat(part.sub(AMPERSAND, ' ').scan(CLASS_TOKEN).flatten)
          else
            names.concat(part.scan(CLASS_TOKEN).flatten)
          end
        end
        names.uniq
      end

      def ids_of(selector)
        selector.to_s.scan(ID_TOKEN).flatten.uniq
      end

      # A reference to a PACKAGE rather than to a file of the tree:
      # `tailwindcss`, `bootstrap/dist/css/bootstrap.css`. The signs are a
      # non-relative path plus an existing directory in node_modules. Telling
      # them apart is mandatory: otherwise live build lines read as broken links.
      def package?(target, root: Xref.root)
        text = target.to_s
        return false if text.empty? || text.start_with?('.', '/', '~', 'http')

        name = text.start_with?('@') ? text.split('/')[0, 2].join('/') : text.split('/').first
        Dir.exist?(File.join(root.to_s, 'node_modules', name.to_s))
      end

      # Where an `@import` leads. The underscore of a partial file is not
      # written in the reference, so there are several candidates — same as in
      # the JavaScript import resolver.
      SUFFIXES = ['', '.scss', '.css', '.sass', '.less'].freeze

      def resolve(from, target, root: Xref.root)
        return nil if target.to_s.empty? || target.to_s.start_with?('http', '//')

        base = File.dirname(from.to_s)
        name = File.basename(target.to_s)
        dir = File.dirname(target.to_s)
        candidates = []
        SUFFIXES.each do |suffix|
          candidates << File.join(dir, "#{name}#{suffix}")
          candidates << File.join(dir, "_#{name}#{suffix}")
        end
        candidates.each do |candidate|
          path = File.expand_path(File.join(base, candidate), root.to_s).delete_prefix("#{root}/")
          return path if File.file?(File.join(root.to_s, path))
        end
        nil
      end
    end
  end
end
