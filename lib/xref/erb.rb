# frozen_string_literal: true

module Xref
  # Assembling Ruby out of an ERB template — once for the whole index.
  #
  # Two different parses need it: call sites (`CallSites`) and the file parse
  # (`CodeScanner`). A copy here would be the worst available option: two
  # implementations of "Ruby out of a template" drift apart silently, and a copy
  # agreeing with the original proves nothing.
  #
  # The key property is LINE NUMBERS. Text outside the tags is replaced by the
  # same number of newlines, so the line of a discovered access matches the line
  # of the template, and the report points at the real place rather than at a
  # shifted one.
  module Erb
    ERB_TAG = /<%(?<kind>[=\-#]?)(?<code>.*?)-?%>/m

    class << self
      def ruby(source)
        out = +''
        position = 0
        each_tag(source) do |code, _line, match|
          out << ("\n" * source[position...match.begin(0)].to_s.count("\n"))
          out << code << ' ; '
          position = match.end(0)
        end
        out << ("\n" * source[position..].to_s.count("\n"))
        out
      end

      # A `<%# … %>` comment is blanked out with spaces rather than dropped:
      # otherwise the columns shift, and with them the offsets of the holes.
      def each_tag(source)
        source.to_enum(:scan, ERB_TAG).each do
          match = Regexp.last_match
          code = match[:kind] == '#' ? match[:code].gsub(/[^\n]/, ' ') : match[:code]
          yield code, source[0...match.begin(0)].count("\n") + 1, match
        end
      end
    end
  end
end
