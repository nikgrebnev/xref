# -*- encoding : utf-8 -*-
require 'spec_helper'

# The journal of verified findings (the specification, part VII, rule 16).
#
# The spec exists for the same reason as the one over the hashing gate: the
# mechanism breaks IN THE DANGEROUS DIRECTION. A verdict of "false" HIDES a
# finding from the reports, and two breakages here stay silent:
#
#   * the subject expression in the class listing and in the filtering drifted
#     apart — the verdict stops finding its own finding, and the report shows
#     the verified again;
#   * the filtering got lost in the listing — and `findings` shows what it
#     declared false itself.
#
# Neither of those fails: the report prints, just with different numbers.
RSpec.describe Xref::Verdicts do
  describe 'the finding classes' do
    it 'gives each of them a title, a view, a condition, a subject and a display' do
      described_class::KINDS.each do |name, spec|
        expect(spec[:title]).to be_present, "у разряда #{name} нет названия"
        expect(spec[:view]).to be_present, "у разряда #{name} нет вида"
        expect(spec[:where]).to be_present, "у разряда #{name} нет условия"
        expect(spec[:subject]).to be_present, "у разряда #{name} нет выражения предмета"
        expect(spec[:show]).to be_present, "у разряда #{name} нечего показать"
        expect(spec).to have_key(:path), "у разряда #{name} не сказано, по какому файлу он стареет"
      end
    end

    # The class name is substituted into SQL as a string (`kind = '…'`), and
    # that is the only place where it does not pass through the connection
    # quoting.
    it 'keeps a class name a plain word with no quotes' do
      described_class.kinds.each do |name|
        expect(name).to match(/\A[a-z][a-z0-9_]*\z/), "имя разряда небезопасно для SQL: #{name}"
      end
    end

    it 'has an unknown class name itself and list the known ones' do
      expect { described_class.kind!('колонка') }
        .to raise_error(Xref::Error, /разряд находок неизвестен.*column/)
    end
  end

  describe '.word' do
    it 'accepts both verdicts in several spellings' do
      ['ложная', 'ЛОЖНАЯ', 'л', 'false', ' f '].each do |input|
        expect(described_class.word(input)).to eq(described_class::WRONG), "не понял «#{input}»"
      end
      ['настоящая', 'н', 'real', 'true'].each do |input|
        expect(described_class.word(input)).to eq(described_class::REAL), "не понял «#{input}»"
      end
    end

    # "Maybe" is not a verdict: the journal hides findings and has no third
    # state.
    it 'does not invent a verdict out of an unclear word' do
      expect(described_class.word('наверное')).to be_nil
      expect { described_class.word!('наверное') }.to raise_error(Xref::Error, /ложная.*настоящая/)
    end
  end

  describe 'filtering out the verified' do
    # The main check of this spec: the subject is written ONCE. Let two
    # spellings drift apart and the verdict stops recognising its own finding,
    # while the report goes on printing as if nothing happened.
    it 'has the listing and the filtering identify a finding with one and the same expression' do
      described_class::KINDS.each do |name, spec|
        expect(described_class.filter_sql(name)).to start_with(spec[:subject])
        expect(described_class.open_sql(name)).to include(spec[:subject])
      end
    end

    it 'always filters the verified out of a class listing' do
      described_class.kinds.each do |name|
        expect(described_class.open_sql(name)).to include('v_finding_hidden')
        expect(described_class.count_sql(name)).to include('v_finding_hidden')
      end
    end

    it 'has the filtering ask the journal about ITS OWN class' do
      expect(described_class.filter_sql('column')).to include("kind = 'column'")
      expect(described_class.filter_sql('locale')).to include("kind = 'locale'")
    end

    # The other side: the lookup of a finding before a verdict is written does
    # NOT apply the filtering. Otherwise a verdict could neither be refined nor
    # rewritten — the finding is already hidden by it.
    it 'does not apply the filtering to the subject lookup before a verdict is written' do
      sql = described_class.lookup_sql('column', "'app/models/x.rb:t.c'")

      expect(sql).not_to include('v_finding_hidden')
      expect(sql).to include("'app/models/x.rb:t.c'")
    end
  end

  describe 'the ageing of a verdict' do
    # A class with no file never goes stale, and that has to be known from the
    # list: such a verdict hides a finding indefinitely, and the report is
    # obliged to say so out loud. One such class is left: an index inside the
    # database has no file at all, while a translation key and a table from a
    # document do have an anchor — the calling file and the first document.
    it 'names the classes whose verdict never goes stale' do
      timeless = described_class::KINDS.reject { |_, spec| spec[:path] }.keys

      expect(timeless).to contain_exactly('index_unused')
    end

    it 'gives the classes with a file a path column in the listing' do
      described_class::KINDS.each do |name, spec|
        next if spec[:path].nil?

        expect(described_class.open_sql(name)).to include("#{spec[:path]} as path"), name
      end
    end
  end
end
