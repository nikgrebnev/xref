# -*- encoding : utf-8 -*-
require 'spec_helper'

# Rule 4 of part VII of the guide, made executable.
#
# `squish` collapses a query into ONE line and takes everything up to the end of
# the query into a `--` comment: the condition is silently switched off while the
# query stays valid and runs. Caught twice — the second time on 2026-10-09 in
# `xref:docs`, where a comment ate the `group by` and the report died halfway
# through. Dying was the lucky outcome: an eaten `and` fails at nothing and
# simply answers the wrong thing.
#
# What is checked is not style but this very trap: a comment on such a query is
# written as a comment OF THE LANGUAGE above the text.
RSpec.describe 'SQL в задачах индекса' do
  # Every heredoc that `squish` is applied to, together with the number of its
  # first line.
  def squished_blocks(source)
    lines = source.lines
    blocks = []
    lines.each_with_index do |line, index|
      next unless line.match?(/<<[~-]SQL\.squish/)

      body = []
      cursor = index + 1
      cursor += 1 while cursor < lines.size && !lines[cursor].match?(/^\s*SQL\s*$/) && (body << lines[cursor])
      blocks << [index + 1, body]
    end
    blocks
  end

  it 'has no SQL comments inside squished queries' do
    %w[lib/tasks/xref.rake].each do |path|
      source = File.read(Xref.root.join(path), encoding: 'UTF-8')
      offenders = squished_blocks(source).flat_map do |start, body|
        body.each_with_index
            .select { |line, _| line.include?('--') }
            .map { |line, offset| "#{path}:#{start + offset + 1}: #{line.strip}" }
      end

      expect(offenders).to be_empty,
                           "комментарий `--` внутри squish съедает остаток запроса:\n#{offenders.join("\n")}"
    end
  end

  # A control over the check itself: if the heredoc parse breaks, the list of
  # blocks becomes empty and the spec starts passing over nothing.
  it 'sees the queries themselves rather than emptiness' do
    source = File.read(Xref.root.join('lib/tasks/xref.rake'), encoding: 'UTF-8')
    blocks = squished_blocks(source)

    expect(blocks.size).to be > 50
    expect(blocks.map { |_, body| body.join }).to all(match(/select|insert|update|delete|create/i))
  end
end
