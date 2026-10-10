# -*- encoding : utf-8 -*-
require 'spec_helper'

# Text search — a wrapper over `rg` with `git grep` as a fallback
# (the specification).
#
# The spec is about two things, and both have already cost a silently wrong
# answer once: parsing the output (the two engines print paths differently) and
# assembling the arguments (without an explicit path `rg` reads standard input
# and finds ZERO).
RSpec.describe Xref::TextSearch do
  after { described_class.reset! }

  def with_tool(command, name)
    described_class.instance_variable_set(:@tool, [command, name])
  end

  describe 'parsing the output' do
    # WITHOUT A LOCALE RUBY ASSUMES THE OUTPUT IS US-ASCII, and the first
    # non-Latin letter brought down `split` with "invalid byte sequence". The
    # whole command died rather than one finding: no report was printed at all,
    # and that read as "the tool is broken" — after which the human goes back to
    # grep, which is exactly what the tool exists to prevent. That is how it is
    # launched from a non-interactive shell and from scripts.
    it 'does not die on non-Latin letters when the external encoding is US-ASCII' do
      row = +"app/models/invoice.rb:42:  # вырез аватара\n"
      out = row.dup.force_encoding(Encoding::US_ASCII)

      hits = described_class.send(:parse, out)

      expect(hits.size).to eq(1)
      expect(hits.first.path).to eq('app/models/invoice.rb')
      expect(hits.first.text).to include('вырез аватара')
    end

    # Genuine garbage in a file must not take the whole hit away.
    it 'replaces a broken byte while keeping the line' do
      out = (+"a.rb:1:\xff ok").force_encoding(Encoding::ASCII_8BIT)

      hits = described_class.send(:parse, out)

      expect(hits.size).to eq(1)
      expect(hits.first.text).to include('ok')
    end

    it 'strips the leading "./" off paths: rg prints it, git grep does not' do
      hits = described_class.parse("./app/models/a.rb:12:код\napp/models/b.rb:3:код\n")

      expect(hits.map(&:path)).to eq(['app/models/a.rb', 'app/models/b.rb'])
    end

    it 'keeps the colons inside the line text: that is code rather than a separator' do
      hits = described_class.parse("a.rb:7:x = {a: 1, b: 2}\n")

      expect(hits.first.text).to eq('x = {a: 1, b: 2}')
      expect(hits.first.line).to eq(7)
    end

    it 'throws away what there is no point searching under any question' do
      hits = described_class.parse("vendor/x.rb:1:код\nnode_modules/y.js:2:код\napp/a.rb:3:код\n")

      expect(hits.map(&:path)).to eq(['app/a.rb'])
    end

    it 'skips lines with no number rather than killing the parse' do
      expect(described_class.parse("мусор без двоеточий\napp/a.rb:5:код\n").size).to eq(1)
    end

    it 'keeps the limit: the answer is truncated rather than growing forever' do
      out = (1..50).map { |i| "app/a.rb:#{i}:код" }.join("\n")

      expect(described_class.parse(out, limit: 10).size).to eq(10)
    end
  end

  describe 'the search arguments' do
    # The most valuable finding of this unit: without a path at the end `rg`,
    # when stdin is not a terminal, reads standard input, exits with code 1 and
    # looks like "this is not in the tree". By hand the same command found
    # 1,282 lines.
    it 'requires a path for rg, otherwise it reads standard input' do
      with_tool(['rg'], 'rg')
      args = described_class.send(:search_arguments, 'нечто', fixed: false, ignore_case: false,
                                                              globs: [], limit: 10)

      expect(args.last).to eq('.')
      expect(args).to include('--regexp', 'нечто')
    end

    # `.claude/*.md` is tracked by git while `rg` by default does not enter
    # dot-directories: the answers of the two engines differed by five hits out
    # of 67.
    it 'has hidden directories enabled for rg, but not .git' do
      with_tool(['rg'], 'rg')
      args = described_class.send(:search_arguments, 'x', fixed: false, ignore_case: false,
                                                          globs: [], limit: 10)

      expect(args).to include('--hidden')
      expect(args.each_cons(2).to_a).to include(%w[--glob !.git/*])
    end

    it 'asks rg for fixed-strings and git grep for -F when searching as text' do
      with_tool(['rg'], 'rg')
      expect(described_class.send(:search_arguments, '[]', fixed: true, ignore_case: false,
                                                           globs: [], limit: 5))
        .to include('--fixed-strings')

      with_tool(%w[git grep], 'git grep')
      expect(described_class.send(:search_arguments, '[]', fixed: true, ignore_case: false,
                                                           globs: [], limit: 5))
        .to include('-F')
    end

    # Path negation is written differently by the two engines, and confusing
    # them means searching somewhere other than asked.
    it 'translates a path negation into the form of its own engine' do
      with_tool(%w[git grep], 'git grep')
      args = described_class.send(:search_arguments, 'x', fixed: false, ignore_case: false,
                                                          globs: ['!doc/schema/*'], limit: 5)

      expect(args).to include(':!doc/schema/*')
    end
  end
end
