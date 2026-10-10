# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'tempfile'

# Queries that ran, from the production logs. The spec is needed for two things,
# each of which silently breaks the meaning: the class of a column ("in a
# condition" against "named in the selection") and the fact that values never
# leave the node.
RSpec.describe Xref::SqlRuntime do
  # TRUNCATION MUST NOT INVENT NAMES. The skeleton is cut by length, and a cut
  # at a character lands in the middle of a name: `… from big_users` became
  # `… from big_`, the parse recorded a table `big_` that does not exist — and
  # that reads as "the code touches a table that is missing". Caught on
  # 2026-10-09 during the collection from pg_profile.
  describe '.trim_tail' do
    it 'leaves a short skeleton alone' do
      expect(described_class.trim_tail('select a from big_users', 1500)).to eq('select a from big_users')
    end

    it 'strips the broken last word off a truncated skeleton' do
      text = "select a from #{'x' * 1480} big_users"[0, 1500]

      expect(text).to end_with('big_u')
      expect(described_class.trim_tail(text, 1500)).to end_with('x')
      expect(described_class.trim_tail(text, 1500)).not_to include('big_')
    end
  end

  describe '.parse' do
    it 'takes the counter and the skeleton, skipping empty lines' do
      out = "12|select a from t where b = 1\n\n3|update t set a = 1\n"
      rows = described_class.parse(out, host: 'node1', day: Date.new(2026, 10, 7))

      expect(rows.map { |row| [row[:hits], row[:skeleton]] })
        .to eq([[12, 'select a from t where b = 1'], [3, 'update t set a = 1']])
      expect(rows.first[:host]).to eq('node1')
    end

    it 'keeps a line with no counter out of the index' do
      expect(described_class.parse("0|select a from t\n|select b from t\n", host: 'n', day: Date.today))
        .to be_empty
    end
  end

  describe '.analyze' do
    let(:known) { Set.new(%w[big_users user_id sex member_age g1]) }

    # The decisive distinction. In production a query selects the field list IN
    # FULL, so "named in the selection" does not mean anyone needs the value;
    # while a column in a condition does work: rows are filtered by it.
    it 'tells a column in a condition from a column in the output list' do
      rows = [{ skeleton: 'select user_id, sex from big_users where member_age > 1 order by sex', hits: 5 }]
      found = described_class.analyze(rows, known: known).first

      expect(found[:tables]).to eq(['big_users'])
      expect(found[:columns]).to include('user_id', 'sex')
      expect(found[:filters]).to contain_exactly('member_age', 'sex')
      expect(found[:writes]).to be_empty
      expect(found[:parsed]).to be(true)
    end

    it 'separates a write target from a read' do
      rows = [{ skeleton: 'update big_users set g1 = 1 where user_id = 1', hits: 2 }]
      found = described_class.analyze(rows, known: known).first

      expect(found[:writes]).to eq(['g1'])
      expect(found[:filters]).to eq(['user_id'])
    end

    it 'marks an unparsed skeleton rather than throwing it away' do
      rows = [{ skeleton: 'select user_id from big_users where (', hits: 1 }]

      expect(described_class.analyze(rows, known: known).first[:parsed]).to be(false)
    end
  end

  # Values must not leave the node: normalisation stands FIRST in the script,
  # before the sorting and the counting. The script itself is checked on a sample
  # of log lines.
  describe 'normalisation on the node' do
    it 'replaces the values while keeping the numbers inside table names' do
      log = [
        "2026-10-07 severity=DEBUG \e[1m\e[35m (0.6ms)\e[0m SELECT * FROM tag_cache4 WHERE user_id in (2001,3002) and lang=E'ru'",
        "2026-10-07 severity=DEBUG SELECT id FROM sessions_live3 WHERE user_id = 12345"
      ].join("\n")
      file = Tempfile.new(['xref-log', '.log'])
      file.write(log)
      file.close
      out = `FILES=#{file.path} sh -c #{Shellwords.escape(described_class::SCRIPT)} 2>/dev/null`
      file.unlink

      expect(out).to include('tag_cache4', 'sessions_live3')
      expect(out).not_to include('2001', '3002', '12345', "'ru'")
    end
  end
end
