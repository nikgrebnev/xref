# -*- encoding : utf-8 -*-
require 'spec_helper'

# Control check B18: "are role conflicts and hidden boundaries visible".
#
# The model review comes BEFORE forbidding violations: forbidding by a wrong
# mapping is worse than not forbidding at all. The first version of the layer
# order was inverted and declared 3,216 ordinary renders to be violations — so
# the order is pinned here by example.
RSpec.describe Xref::Components do
  def component(role, paths: ['x/%'], except: [])
    described_class::Component.new(name: role, role: role, paths: paths, except: except)
  end

  describe 'the layer order' do
    it 'has a controller depend on a template rather than the other way round' do
      expect(described_class.upward?(component('api'), component('ui'))).to be(false)
      expect(described_class.upward?(component('ui'), component('api'))).to be(true)
    end

    it 'has a service depend on the domain, and the reverse is a violation' do
      expect(described_class.upward?(component('service'), component('domain'))).to be(false)
      expect(described_class.upward?(component('domain'), component('service'))).to be(true)
    end

    it 'allows everyone to depend on the shared housekeeping' do
      expect(described_class.upward?(component('api'), component('shared'))).to be(false)
      expect(described_class.upward?(component('domain'), component('shared'))).to be(false)
    end

    it 'lets tests depend on anything while nothing depends on them' do
      expect(described_class.upward?(component('test'), component('api'))).to be(false)
      expect(described_class.upward?(component('api'), component('test'))).to be(true)
    end
  end

  describe 'patterns with an exception' do
    it 'keeps a file out of two components at once through the exception' do
      shared = component('shared', paths: ['lib/%'], except: ['lib/tasks/%'])
      conn = Xref::Store.conn

      expect(shared.condition(conn)).to include('not like')
      expect(conn.select_value("select ('lib/tasks/x.rake' like 'lib/%')")).to be(true)
      expect(conn.select_value(<<~SQL.squish)).to be(false)
        select #{shared.condition(conn).gsub('path', "'lib/tasks/x.rake'")}
      SQL
    end
  end

  # One back-reference against a hundred forward ones is not an absorbed
  # responsibility.
  describe 'the threshold of a real cycle' do
    it 'calls nine edges against nineteen a cycle' do
      expect(9 >= described_class::CYCLE_MIN_EDGES &&
             9 >= 19 * described_class::CYCLE_MIN_SHARE).to be(true)
    end

    it 'does not call three edges against a hundred and sixty-four a cycle' do
      expect(3 >= described_class::CYCLE_MIN_EDGES).to be(false)
    end
  end
end
