# -*- encoding : utf-8 -*-
require 'spec_helper'

# The gate in front of hashing (the specification).
#
# The spec exists because this unit breaks IN THE DANGEROUS DIRECTION: if the
# gate stops letting a changed file through, the index starts answering from
# stale content while looking fresh. So what is checked below is both the saving
# (what is not hashed) and its safety (what is noticed anyway).
RSpec.describe Xref::ScanPlan do
  let(:inputs) { 'входы-1' }

  def plan(paths, stored:, inputs_sha: inputs, full: false, mtime:, digest:)
    described_class.call(paths, stored: stored, inputs_sha: inputs_sha, full: full,
                                mtime: ->(p) { mtime[p] }, digest: ->(p) { digest[p] })
  end

  it 'does not compute the SHA of a file whose modification time did not change' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, 100.0] },
                            mtime: { 'a.rb' => 100.0 },
                            digest: { 'a.rb' => 'НЕ-ДОЛЖНО-ПОНАДОБИТЬСЯ' })

    expect(result.hashed).to be_empty
    expect(result.changed).to be_empty
    expect(result.current['a.rb']).to eq('sha-a')
  end

  # The main check: the saving must not hide an edit.
  it 'computes the SHA on a different modification time and sees the change' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, 100.0] },
                            mtime: { 'a.rb' => 200.0 },
                            digest: { 'a.rb' => 'sha-b' })

    expect(result.hashed).to eq(['a.rb'])
    expect(result.changed).to eq('a.rb' => 'sha-b')
  end

  # A `touch` with no edit to the content: the SHA had to be computed while
  # there is nothing to parse.
  it 'does not repeat the parse on a different time with identical content' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, 100.0] },
                            mtime: { 'a.rb' => 200.0 },
                            digest: { 'a.rb' => 'sha-a' })

    expect(result.hashed).to eq(['a.rb'])
    expect(result.changed).to be_empty
  end

  # The schema or the parser itself changed — the files are the same while
  # everything has to be parsed. Without this condition the gate would let the
  # whole index through by modification time.
  it 'hashes and parses everything when the input digest changes' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', 'входы-0', 100.0] },
                            mtime: { 'a.rb' => 100.0 },
                            digest: { 'a.rb' => 'sha-a' })

    expect(result.hashed).to eq(['a.rb'])
    expect(result.changed).to eq('a.rb' => 'sha-a')
  end

  it 'hashes a file with no remembered time: rows from earlier versions of the index' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, nil] },
                            mtime: { 'a.rb' => 100.0 },
                            digest: { 'a.rb' => 'sha-a' })

    expect(result.hashed).to eq(['a.rb'])
    expect(result.changed).to be_empty
  end

  it 'has FULL=1 hash and parse everything, even on a matching time' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, 100.0] }, full: true,
                            mtime: { 'a.rb' => 100.0 },
                            digest: { 'a.rb' => 'sha-a' })

    expect(result.hashed).to eq(['a.rb'])
    expect(result.changed).to eq('a.rb' => 'sha-a')
  end

  it 'calls a vanished file vanished rather than changed' do
    result = plan(['a.rb'], stored: { 'a.rb' => ['sha-a', inputs, 100.0],
                                      'b.rb' => ['sha-b', inputs, 100.0] },
                            mtime: { 'a.rb' => 100.0 },
                            digest: {})

    expect(result.removed).to eq(['b.rb'])
    expect(result.changed).to be_empty
  end

  it 'hashes and parses a new file' do
    result = plan(%w[a.rb new.rb], stored: { 'a.rb' => ['sha-a', inputs, 100.0] },
                                   mtime: { 'a.rb' => 100.0, 'new.rb' => 50.0 },
                                   digest: { 'new.rb' => 'sha-new' })

    expect(result.hashed).to eq(['new.rb'])
    expect(result.changed).to eq('new.rb' => 'sha-new')
  end
end
