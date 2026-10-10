# -*- encoding : utf-8 -*-
require 'spec_helper'

# The collector of facts from the live data (the specification (the "fill rates"
# section).
#
# The spec exists because each of the three traps below has already spoiled a
# measurement once: `boolean <> 0` killed a whole run, a default passed an empty
# column off as filled for every row, and the total count did not tell a dead
# mechanism from a live one. What is checked is the query that gets built rather
# than a trip to the database: the traps live in the query.
RSpec.describe Xref::DataFacts do
  def built_sql(columns, table: 'probe')
    sql = nil
    allow(Xref::SchemaSource).to receive(:new).and_return(instance_double(Xref::SchemaSource))
    allow(Xref::SchemaSource.new('prod_a')).to receive(:run) { |text| sql = text; '' }
    described_class.send(:measure, 'prod_a', table, columns)
    sql
  end

  it 'compares by type: boolean is not compared with zero, text with an empty string' do
    sql = built_sql([%w[flag boolean f], ['note', 'text', ''], ['n', 'smallint', '']])

    expect(sql).to include('count(*) filter (where "flag")')
    expect(sql).to include(%(count(*) filter (where "note" is not null and "note" <> '')))
    expect(sql).to include('count(*) filter (where "n" is not null and "n" <> 0)')
    expect(sql).not_to include('"flag" <> 0')
  end

  # Previously everything unknown was compared with zero, and the first
  # `interval` killed an ENTIRE run: 24 tables were left unmeasured because of
  # one column.
  it 'compares with zero only for numbers, an unknown type only against null' do
    sql = built_sql([['amount', 'numeric', ''], ['span_length', 'interval', ''],
                     ['meta', 'tsvector', '']], table: 'payments')

    expect(sql).to include('"amount" is not null and "amount" <> 0')
    expect(sql).to include('"span_length" is not null')
    expect(sql).not_to include('"span_length" is not null and "span_length" <> 0')
    expect(sql).not_to include('"meta" <> 0')
  end

  it 'for a column with a default counts the deviation from the default, not from zero' do
    sql = built_sql([['notify', 'smallint', '1']])

    expect(sql).to include('"notify" is not null and "notify" is distinct from (1)')
  end

  it 'does not invent the second counter where there is no default' do
    sql = built_sql([['note', 'text', '']])

    expect(sql).to include('null::bigint')
    expect(sql).not_to include('is distinct from')
  end

  # The list of recency columns is a habit of a tree, so the example NAMES it
  # instead of taking whatever the host project happens to configure: a spec that
  # leans on the tree it runs in is green in one and red in another.
  it 'takes the recent cohort by a known registration column' do
    allow(Xref).to receive(:idioms)
      .and_return(Xref::IDIOM_DEFAULTS.merge(recency_columns: %w[member_signup created_at]))
    sql = built_sql([['member_signup', 'integer', ''], ['n', 'smallint', '']])

    expect(sql).to include(%("member_signup" > extract(epoch from now() - interval '1 year')))
  end

  it 'compares a real-date cohort against now() rather than against the epoch' do
    sql = built_sql([['created_at', 'timestamp without time zone', ''], ['n', 'smallint', '']])

    expect(sql).to include(%("created_at" > now() - interval '1 year'))
    expect(sql).not_to include('extract(epoch')
  end

  it 'does not invent a cohort where there is no date column' do
    sql = built_sql([['n', 'smallint', '']])

    expect(sql).not_to include('interval')
  end

  # The column name comes from a schema snapshot, but it still has to be quoted:
  # the tables of this tree hold columns `desc`, `show`, `count` — without quotes
  # the query will not parse at all.
  it 'quotes the names — there are keywords among the columns' do
    sql = built_sql([['desc', 'text', '']], table: 'show')

    expect(sql).to include('from "show"')
    expect(sql).to include('"desc" is not null')
  end
end
