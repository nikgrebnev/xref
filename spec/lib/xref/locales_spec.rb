# -*- encoding : utf-8 -*-
require 'spec_helper'

# The translation store is read BYPASSING I18n: the project has fallbacks
# enabled, and `I18n.t` is green always — wherever a translation is missing,
# English quietly arrives. Hence a spec over the file parse, and above all over
# the two places where it is easy to count wrongly: plural forms and nesting.
RSpec.describe Xref::Locales do
  def with_locale_file(name, text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config/locales')
      FileUtils.mkdir_p(path)
      File.write(File.join(path, name), text)
      yield dir
    end
  end

  it 'collapses nesting into a dotted key, per language' do
    with_locale_file('en.yml', "en:\n  login:\n    invalid: \"no\"\nru:\n  login:\n    invalid: \"нет\"\n") do |dir|
      rows = described_class.collect(root: dir)

      expect(rows.map { |row| [row[:lang], row[:key]] })
        .to contain_exactly(%w[en login.invalid], %w[ru login.invalid])
    end
  end

  # Plural forms are ONE key rather than five. Counting `one`/`other` as keys
  # breaks the comparison against the code: the code calls `mail.count` while the
  # store holds `mail.count.one` and `mail.count.other`, and the key is listed as
  # missing.
  it 'counts plural forms as one key' do
    with_locale_file('en.yml', "en:\n  mail:\n    count:\n      one: \"1\"\n      other: \"%{n}\"\n") do |dir|
      expect(described_class.collect(root: dir).map { |row| row[:key] }).to eq(['mail.count'])
    end
  end

  it 'does not glue ordinary nesting with similar names into a key' do
    with_locale_file('en.yml', "en:\n  a:\n    one: \"1\"\n    two: \"2\"\n    three: \"3\"\n") do |dir|
      # `one`/`two` are forms, but `three` is never a form: that is an ordinary
      # hash.
      expect(described_class.collect(root: dir).map { |row| row[:key] })
        .to contain_exactly('a.one', 'a.two', 'a.three')
    end
  end

  it 'a broken file does not kill the parse of the rest and comes back as its own record' do
    with_locale_file('bad.yml', "en:\n  a: [unclosed\n") do |dir|
      rows = described_class.collect(root: dir)

      expect(rows.size).to eq(1)
      expect(rows.first[:lang]).to eq('?')
    end
  end
end
