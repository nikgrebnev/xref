# -*- encoding : utf-8 -*-
require 'spec_helper'

# THE TWO ROOTS of the tool: the directory of the tool itself and the tree it
# indexes (the specification, III.3).
#
# The spec exists because a mistake here does not fail but SILENTLY answers
# about another tree: with a separate installation (its own directory, its own
# bundle) `project_root` is the only thing that tells "I index the project" from
# "I index myself".
RSpec.describe Xref do
  after { described_class.reload_config! }

  describe '.home' do
    it 'is the tool directory, and its configuration lives there' do
      expect(described_class.home.join('config/xref.yml')).to exist
      expect(described_class.home.join('lib/xref.rb')).to exist
    end
  end

  describe '.root' do
    it 'takes the tree from project_root when it is set' do
      allow(described_class).to receive(:config).and_return(project_root: '/tmp/another-tree')
      described_class.instance_variable_set(:@root, nil)

      expect(described_class.root.to_s).to eq('/tmp/another-tree')
    end

    # A relative path is resolved against the TOOL directory rather than the
    # current one: a query is called from anywhere in the tree, and `Dir.pwd`
    # must not decide here.
    it 'resolves a relative path against the tool directory' do
      allow(described_class).to receive(:config).and_return(project_root: '../neighbour')
      described_class.instance_variable_set(:@root, nil)

      expect(described_class.root.to_s).to eq(described_class.home.join('../neighbour').to_s)
    end

    it 'without project_root, inside an application, it is the application root' do
      skip 'no application loaded: this installation is standalone' unless defined?(Rails)

      allow(described_class).to receive(:config).and_return({})
      described_class.instance_variable_set(:@root, nil)

      expect(described_class.root.to_s).to eq(Rails.root.to_s)
    end
  end
end
