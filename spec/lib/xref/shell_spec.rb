# -*- encoding : utf-8 -*-
require 'spec_helper'

# Parsing shell scripts (the specification).
#
# The spec is about one main distinction: a variable of THE SCRIPT against a key
# of THE ENVIRONMENT. Without it 111 names out of 442 landed among the
# "environment keys" — `sha`, `img`, `path`, `attempt` — and the report about the
# environment turned into garbage. The error here goes in the dangerous
# direction: that report is what people judge by whether a key is defined in
# production.
RSpec.describe Xref::Shell do
  def kinds(source, kind)
    described_class.elements(source).select { |e| e.kind == kind }.map(&:text)
  end

  it 'takes a variable expansion in both forms' do
    expect(kinds('echo "$HOME и ${USER}"', 'variable')).to contain_exactly('HOME', 'USER')
  end

  it 'marks a default: that is an ordinary setting rather than a hole' do
    found = described_class.elements('P=${DB_HOST:-node9}').select { |e| e.kind == 'variable' }

    expect(found.map { |e| [e.text, e.extra[:default]] }).to eq([['DB_HOST', true]])
  end

  it 'does not count positional and special variables as environment keys' do
    expect(kinds('echo "$1 $? $@"', 'variable')).to be_empty
  end

  # Three ways of receiving a value with no equals sign. While they were
  # missing, names out of loops travelled into the environment keys.
  it 'counts a name from a loop, from read and from local as bound' do
    source = <<~SH
      for host in a b; do echo $host; done
      while read -r line; do echo $line; done
      f() { local tmp=1; echo $tmp; }
    SH

    expect(kinds(source, 'bound')).to include('host', 'line', 'tmp', 'f')
  end

  it 'does not treat a comment as code' do
    expect(kinds('# $SECRET только в комментарии', 'variable')).to be_empty
  end

  it 'returns the heredoc body whole and as its own element' do
    source = <<~SH
      psql <<'SQL'
      select id from member_contacts;
      SQL
    SH
    found = described_class.elements(source).select { |e| e.kind == 'heredoc' }

    expect(found.size).to eq(1)
    expect(found.first.text).to eq("select id from member_contacts;\n")
  end

  it 'does not record variables inside a heredoc separately: that is foreign text' do
    source = "cat <<EOF\n\$NOT_A_KEY\nEOF\n"

    expect(kinds(source, 'variable')).to be_empty
  end

  it 'takes only the commands people ask about' do
    source = "echo привет\nssh node1 'docker ps'\nрандом\n"

    expect(kinds(source, 'command')).to contain_exactly('ssh', 'docker')
  end

  it 'marks removal and overwriting' do
    expect(kinds("rm -rf \"$dir\"\n", 'dangerous')).not_to be_empty
    expect(kinds("chmod 777 /tmp/x\n", 'dangerous')).not_to be_empty
    expect(kinds("rm вот_этот_файл\n", 'dangerous')).to be_empty
  end
end
