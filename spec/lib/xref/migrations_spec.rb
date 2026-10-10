# -*- encoding : utf-8 -*-
require 'spec_helper'

# Which migrations are applied in each environment. A spec over the comparison,
# because mixing three different cases here is the easiest thing of all: "not
# applied" (a deploy risk), "applied but no file" (the file was deleted or came
# from another branch) and the old short numbers, for which files never existed.
RSpec.describe Xref::Migrations do
  describe '.compare' do
    let(:repo) { %w[20260101000000 20260102000000 20260103000000] }

    it 'names the unapplied separately from the surplus' do
      applied = { 'prod_a' => %w[20260101000000 20260102000000 20260999000000] }
      report = described_class.compare(applied, repo)['prod_a']

      expect(report[:applied]).to eq(3)
      expect(report[:missing]).to eq(['20260103000000'])
      expect(report[:extra]).to eq(['20260999000000'])
    end

    # The short numbers are a Rails 2 legacy. There are no files for them and
    # there cannot be, and they must not land among the "surplus": otherwise the
    # report always shouts about sixteen surplus migrations and people stop
    # reading it.
    it 'keeps the old short numbers out of the comparison with the tree' do
      applied = { 'prod_a' => (repo + %w[15 16 23]) }
      report = described_class.compare(applied, repo)['prod_a']

      expect(report[:legacy]).to eq(3)
      expect(report[:extra]).to be_empty
      expect(report[:missing]).to be_empty
    end

    it 'tells the environments apart: each has its own answer' do
      applied = { 'prod_a' => repo, 'prod_b' => repo.first(1) }
      report = described_class.compare(applied, repo)

      expect(report['prod_a'][:missing]).to be_empty
      expect(report['prod_b'][:missing].size).to eq(2)
    end
  end

  describe '.in_repo' do
    it 'takes the number from the file name and only timestamps' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'db/migrate'))
        %w[20260101000000_a.rb 20260102000000_b.rb 15_legacy.rb notes.txt].each do |name|
          File.write(File.join(dir, 'db/migrate', name), '')
        end

        expect(described_class.in_repo(root: dir)).to eq(%w[20260101000000 20260102000000])
      end
    end
  end
end
