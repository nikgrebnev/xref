# -*- encoding : utf-8 -*-
require 'spec_helper'

# Parsing documentation (the specification (the section about the document
# layer).
#
# The spec exists because the main danger of this parse is A FALSE ALARM. A
# document is full of illustrative examples, sketches with omissions and
# quotations cut off mid-branch; a parse that calls them defects issues 137
# findings of which fourteen are real, and devalues every other answer the index
# gives.
RSpec.describe Xref::Markdown do
  def kinds(source)
    described_class.elements(source).map { |element| [element.kind, element.text.strip[0, 40]] }
  end

  describe 'parsing into parts' do
    it 'takes a heading with its level and line number' do
      element = described_class.elements("текст\n\n## Раздел про почту\n").first

      expect(element.kind).to eq('heading')
      expect(element.text).to eq('Раздел про почту')
      expect(element.extra[:level]).to eq(2)
      expect(element.line).to eq(3)
    end

    # Inside a code block `#` is a comment of the language and `[a](b)` is a
    # call. While the blocks were not cut out first, the parse found headings in
    # SQL and links in Ruby.
    it 'sees no headings and no links inside a code block' do
      source = <<~MD
        # A real heading

        ```ruby
        # not a heading
        link = fetch[:a](:b)
        ```
      MD

      expect(kinds(source)).to contain_exactly(['heading', 'A real heading'],
                                               ['code', "# not a heading\nlink = fetch[:a](:b)"])
    end

    it 'lets an unclosed block run to the end of the file — that is how the renderer reads it too' do
      element = described_class.elements("```sql\nselect 1\nselect 2\n").find { |e| e.kind == 'code' }

      expect(element.extra[:unclosed]).to be(true)
      expect(element.text).to eq("select 1\nselect 2\n")
    end

    it 'tells a link from a wiki link' do
      found = described_class.elements("см. [план](doc/plan.md) и [[памятка-про-почту]]\n")

      expect(found.map { |e| [e.text, e.extra[:wiki]] })
        .to contain_exactly(['doc/plan.md', nil], ['памятка-про-почту', true])
    end

    it 'takes backticks, including the doubled ones' do
      found = described_class.elements("тут `big_users`, а тут ``a`b``\n").select { |e| e.kind == 'span' }

      expect(found.map(&:text)).to contain_exactly('big_users', 'a`b')
    end
  end

  describe 'does it look like a path' do
    it 'says yes to a path with a directory or with an extension' do
      expect(described_class.path_like?('app/models/address.rb')).to be(true)
      expect(described_class.path_like?('schema.sql')).to be(true)
    end

    # Each of the three once produced a false finding or killed the parse.
    it 'says no to: a bare extension, an ellipsis, a home directory' do
      expect(described_class.path_like?('.rb')).to be(false)
      expect(described_class.path_like?('app/views/theme_desktop/...')).to be(false)
      expect(described_class.path_like?('~jquery.touchslider.js')).to be(false)
    end

    it 'does not treat a URL as a path' do
      expect(described_class.path_like?('https://example.org/a.rb')).to be(false)
    end
  end

  # "No such file" is asserted only about a path anchored to the root of the
  # tree. Otherwise every illustrative example in the guide would become a broken
  # link.
  describe 'anchoring to the root' do
    it 'calls a known directory at the start anchored' do
      expect(described_class.rooted?('app/models/x.rb')).to be(true)
      expect(described_class.rooted?('spec/lib/y_spec.rb')).to be(true)
    end

    it 'does not call an invented example with no directory anchored' do
      expect(described_class.rooted?('user_profile.rb')).to be(false)
      expect(described_class.rooted?('models/user.rb')).to be(false)
    end
  end
end
