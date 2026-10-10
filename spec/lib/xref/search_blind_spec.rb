# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'tmpdir'

# A FILE THE TEXT SEARCH CANNOT SEE (the specification, part X).
#
# A zero byte inside a file makes it binary for the search, and from there the
# worst begins: `rg` with our flags returns NOTHING and exits with the code for
# "not found", while `git grep` prints "Binary file … matches" instead of the
# lines — and the output parser throws such a line away. The file meanwhile
# passes `ruby -c` and the linter.
#
# In another project a live service sat like that, answering no search at all,
# and it was found by eye. So the index is obliged to KNOW about such files and
# to say so: the parse does read them — NUL is legitimate UTF-8 and neither
# reading nor scrubbing removes it.
RSpec.describe 'слепота текстового поиска' do
  # There must be no NUL literal in this file — otherwise the spec about
  # invisibility would make itself invisible. Hence the escape, and exactly the
  # same rule applies in the parser.
  let(:nul) { "\u0000" }

  describe 'Xref::CodeScanner' do
    it 'marks a file with a NUL byte as invisible to the search' do
      source = "def hidden_method\n  \"#{nul}\"\nend\n"

      refs = Xref::CodeScanner.new('app/services/hidden.rb', source).scan

      expect(refs.map(&:kind)).to include('search_blind')
    end

    it 'does not mark an ordinary file that way' do
      refs = Xref::CodeScanner.new('app/services/plain.rb', "def plain\n  1\nend\n").scan

      expect(refs.map(&:kind)).not_to include('search_blind')
    end
  end

  # This is not a check of our code but A RECORD OF A MEASUREMENT: while it is
  # green, the line "the search cannot see N files" has to stay in the reports.
  # If one day a search engine starts returning such files, the example will
  # fail — and that is a good reason to remove the line rather than let it lie
  # in the other direction.
  describe 'the search layer', :aggregate_failures do
    it 'loses a hit from a file with a NUL byte' do
      Dir.mktmpdir('xref-nul') do |dir|
        root = Pathname.new(dir)
        root.join('plain.rb').write("def visible_method\n  1\nend\n")
        root.join('withnul.rb').write("def hidden_method\n  \"#{nul}\"\nend\n")
        system('git', 'init', '-q', dir, out: File::NULL, err: File::NULL)

        expect(Xref::TextSearch.lines('visible_method', root: root).map(&:path)).to eq(['plain.rb'])
        expect(Xref::TextSearch.lines('hidden_method', root: root)).to be_empty
      end
    end
  end
end
