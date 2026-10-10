# -*- encoding : utf-8 -*-
require 'spec_helper'

# Control check B04 from the registry of problems of agent work on a large
# codebase: "is a new forbidden call detected". A rule nobody runs stops working
# silently — the report goes on printing.
#
# Hence two different kinds of example here. The first is about the latch itself
# (pure logic). The second is A GUARD: it fails when the architecture has got
# worse, that is, when a new violation appeared in the tree beyond what the
# configuration records.
RSpec.describe Xref::Rules do
  def result(count, limit)
    described_class::Result.new(name: 'правило', why: '', from: 'a/%', to: 'b/%', limit: limit,
                                rows: Array.new(count) { |i| { 'from_path' => "a/#{i}.rb" } })
  end

  describe 'the latch' do
    it 'shouts when there are more violations' do
      expect(result(8, 7)).to be_grown
      expect(result(8, 7).state).to eq('ВЫРОСЛО')
    end

    it 'stays silent when the number did not change' do
      expect(result(7, 7)).not_to be_grown
      expect(result(7, 7).state).to eq('в пределах защёлки')
    end

    it 'suggests lowering the latch when there are fewer violations' do
      expect(result(5, 7)).not_to be_grown
      expect(result(5, 7).state).to include('опустить')
    end

    it 'counts files rather than edges: the same edge occurs twice in one file' do
      rows = [{ 'from_path' => 'a/one.rb' }, { 'from_path' => 'a/one.rb' }, { 'from_path' => 'a/two.rb' }]
      found = described_class::Result.new(name: 'r', why: '', from: '', to: '', limit: 9, rows: rows)

      expect([found.count, found.files]).to eq([3, 2])
    end
  end

  # A contract declared in prose, and its latch. Three states, and the middle
  # one is the most useful: the latch file exists but does not name the subject
  # of the contract, that is, it passes while guarding nothing.
  describe 'contracts' do
    def contract(latch: 'spec/latch_spec.rb', token: 'предмет', latch_exists: true, files: 1)
      described_class::Contract.new(name: 'контракт', doc: 'doc/c.md', latch: latch, token: token,
                                    doc_exists: true, latch_exists: latch_exists, token_files: files)
    end

    it 'calls one with no latch broken' do
      expect(contract(latch: '')).to be_broken
      expect(contract(latch: '').state).to include('НЕТ ЗАЩЁЛКИ')
    end

    it 'calls one whose named latch file is missing broken' do
      expect(contract(latch_exists: false)).to be_broken
      expect(contract(latch_exists: false).state).to include('ПОТЕРЯНА')
    end

    # This is the very finding the check exists for: the spec is there, it is
    # green, and it says not a word about the subject of the contract.
    it 'calls one whose latch does not name the subject broken' do
      expect(contract(files: 0)).to be_broken
      expect(contract(files: 0).state).to include('не называет')
    end

    it 'calls one whose latch exists and names the subject intact' do
      expect(contract).not_to be_broken
      expect(contract.state).to eq('защёлкнут')
    end

    # The subject is searched AS TEXT inside the latch file rather than through
    # the index: the index only records the `token` kind for names from a schema,
    # while a contract subject is `structure.sql` or a class name. Checking
    # through the index answered "does not name it" for every contract at once.
    it 'searches for the subject as text inside the latch file' do
      expect(Xref::TextSearch).to receive(:lines)
        .with('предмет', hash_including(fixed: true, globs: ['spec/latch_spec.rb'])).and_return([])

      expect(described_class.contracts([{ name: 'к', doc: 'doc/c.md',
                                          latch: 'spec/latch_spec.rb', token: 'предмет' }])
                            .first.token_files).to eq(0)
    end
  end

  # This example is not about the code of the tool but about the state of the
  # tree. It fails when somebody added a forbidden dependency and did not
  # explain it in the configuration. An empty graph does NOT count as success:
  # zero violations for any rule over an empty graph means "nobody looked".
  describe 'the architecture guard' do
    it 'has no rule grown beyond its latch' do
      skip 'индекс кода пуст — нечего проверять (bin/xref app && bin/xref code)' unless described_class.ready?

      grown = described_class.check.select(&:grown?)
      message = grown.map { |r| "#{r.name}: #{r.count} против защёлки #{r.limit}" }.join('; ')

      expect(grown).to be_empty, "архитектура ухудшилась — #{message}. " \
                                 'Либо уберите новое нарушение, либо поднимите защёлку в ' \
                                 'config/xref.yml с объяснением в коммите'
    end
  end
end
