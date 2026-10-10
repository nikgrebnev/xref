# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'tmpdir'

# Finding call sites on demand (the specification ("who calls it and what they
# pass").
#
# The parse goes over real files, so the spec writes files too: there is nothing
# to stub the reading with, and the whole point is exactly HOW an .erb file is
# read and where the line numbers come from.
RSpec.describe Xref::CallSites do
  around do |example|
    Dir.mktmpdir('xref-calls') do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  def write(path, body)
    full = @root.join(path)
    FileUtils.mkdir_p(full.dirname)
    full.write(body)
    path
  end

  def find(names, paths)
    described_class.find(Array(names), root: @root, paths: Array(paths))
  end

  it 'does not count a declaration itself as a call' do
    path = write('app/models/probe.rb', <<~'RUBY')
      class Probe
        def make_param(sql, table)
          ["user_id in (#{sql})"]
        end
      end
    RUBY

    expect(find('make_param', path)).to be_empty
  end

  it 'names the file, the line, the surrounding method and the arguments' do
    path = write('app/models/caller.rb', <<~'RUBY')
      class Caller
        def run
          make_param(additional_sql, 'big_users_live')
        end
      end
    RUBY
    call = find('make_param', path).first

    expect([call.path, call.line, call.scope]).to eq([path, 3, 'Caller#run'])
    expect(call.args).to eq(['additional_sql', "'big_users_live'"])
    expect(call.via).to be_nil
  end

  # Helpers are called from views, and without parsing the templates "who calls
  # it" lied in the most frequent direction: one path helper came out with 4
  # calls instead of 19.
  describe 'ERB templates' do
    it 'assembles Ruby out of the tags and keeps the line numbers' do
      path = write('app/views/home/show.html.erb', <<~'ERB')
        <h1>Заголовок</h1>
        <%= render :partial => bootstrap_partial_path('home/menu') %>
        <p>текст</p>
        <% if visible? %>
          <%= bootstrap_partial_path('home/footer') %>
        <% end %>
      ERB
      calls = find('bootstrap_partial_path', path)

      expect(calls.map(&:line)).to eq([2, 5])
      expect(calls.map(&:via).uniq).to eq(['шаблон'])
      expect(calls.map { |call| call.args.first }).to eq(["'home/menu'", "'home/footer'"])
    end

    it 'parses a branch spread across different tags' do
      path = write('app/views/home/branch.html.erb', <<~'ERB')
        <% if ready? %>
          <%= helper_under_test(1) %>
        <% else %>
          <%= helper_under_test(2) %>
        <% end %>
      ERB

      expect(find('helper_under_test', path).map(&:line)).to eq([2, 4])
    end

    it 'does not look inside an ERB comment' do
      path = write('app/views/home/commented.html.erb', "<%# helper_under_test(1) %>\n")

      expect(find('helper_under_test', path)).to be_empty
    end
  end

  describe 'send' do
    it 'counts a literal name as a call and returns the remaining arguments' do
      path = write('app/models/sender.rb', <<~'RUBY')
        class Sender
          def run(object)
            object.send(:find_session, sid, 1)
            object.public_send('find_session', sid)
          end
        end
      RUBY
      calls = find('find_session', path)

      expect(calls.map(&:via).uniq).to eq(['send'])
      expect(calls.first.args).to eq(%w[sid 1])
    end

    it 'counts a name assembled at runtime separately and does not call it a call' do
      path = write('app/models/dynamic.rb', <<~'RUBY')
        class Dynamic
          def run(action)
            send(action, 1)
          end
        end
      RUBY
      stats = {}
      calls = described_class.find(['find_session'], root: @root, paths: [path], stats: stats)

      expect(calls).to be_empty
      expect(stats[:dynamic_sends]).to eq(1)
    end
  end

  # `before_action :check_gate` does not call the method but keeps it alive.
  # Without this half the private methods of the controllers would be listed as
  # dead.
  it 'treats a symbol as the same kind of hook as a call' do
    path = write('app/controllers/probe_controller.rb', <<~'RUBY')
      class ProbeController < ApplicationController
        before_action :check_gate, only: [:index]

        private

        def check_gate; end
      end
    RUBY
    call = find('check_gate', path).first

    expect([call.via, call.line]).to eq(['символ', 2])
  end

  describe 'mentions outside calls' do
    it 'sorts them by class and does not count a declaration as a mention' do
      write('app/models/probe.rb', "class Probe\n  def make_param(sql); end\nend\n")
      write('spec/security/guard_spec.rb', "# make_param(sql, table) — исключение сторожа\n")
      write('doc/audit.md', "Метод `make_param` разобран в аудите\n")
      Dir.chdir(@root) { `git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm x` }

      found = described_class.mentions('make_param', root: @root)

      expect(found.map(&:kind)).to contain_exactly('спека', 'документ')
      expect(found.map(&:path)).not_to include('app/models/probe.rb')
    end
  end

  # "Dead" without the list of what holds the method leads to "I will delete
  # it", so an error here is dangerous in one direction: A MISSED mention. The
  # previous full pass over the tree missed two classes at once, and both are
  # checked below.
  describe 'mentions of hundreds of names at once' do
    it 'finds a mention in a spec and in a document without counting the declaration' do
      write('app/models/probe.rb', "class Probe\n  def make_param(sql); end\nend\n")
      write('spec/security/guard_spec.rb', "# make_param(sql, table) — исключение сторожа\n")
      write('doc/audit.md', "Метод `make_param` разобран в аудите\n")

      found = described_class.mentions_many(%w[make_param], root: @root)

      expect(found['make_param'].map(&:kind)).to contain_exactly('спека', 'документ')
      expect(found['make_param'].map(&:path)).not_to include('app/models/probe.rb')
    end

    # A file larger than four megabytes is not read by the full pass at all —
    # and the tree holds machine-generated inventories in such files, with 412
    # mentions in them that the previous answer never saw.
    it 'sees a mention in a file larger than four megabytes' do
      write('doc/schema/source_index.json', "#{'{"filler":"x"},' * 300_000}\n{\"method\":\"make_param\"}\n")
      expect(File.size(@root.join('doc/schema/source_index.json'))).to be > 4_000_000

      found = described_class.mentions_many(%w[make_param], root: @root)

      expect(found['make_param'].map(&:path)).to include('doc/schema/source_index.json')
    end

    # The tree holds 45 methods with non-Latin names. The previous word pattern
    # (`[A-Za-z_]`) did not see their mentions, so a method with a non-Latin name
    # read as "mentioned nowhere" — and went into the removal candidates.
    it 'sees a mention of a method with a non-Latin name' do
      write('doc/audit.md', "Метод `ключ_входа` разобран в аудите\n")

      found = described_class.mentions_many(%w[ключ_входа], root: @root)

      expect(found['ключ_входа'].map(&:path)).to eq(['doc/audit.md'])
    end

    # Truncating the search answer lies in the same dangerous direction, so on
    # hitting the limit the caller is obliged to get THE FULL pass rather than a
    # short answer.
    it 'falls back to the full pass when the search answer is truncated' do
      write('doc/audit.md', "Метод `make_param` разобран в аудите\n")
      Dir.chdir(@root) { `git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm x` }

      stats = {}
      found = described_class.mentions_many(%w[make_param], root: @root, limit: 1, stats: stats)

      expect(stats[:scan]).to include('полный проход')
      expect(found['make_param'].map(&:path)).to eq(['doc/audit.md'])
    end
  end

  describe 'URLs written as strings' do
    # A URL at THE START of a line: a text search looks line by line, and
    # without `^` in the pattern 902 URLs out of ten thousand were lost.
    it 'finds a URL at the start of a line' do
      write('app/views/probe.html.erb', "/gal/details\n<a href=\"/user/save\">x</a>\n")

      found = described_class.literal_paths(root: @root)

      expect(found).to include('/gal/details', '/user/save')
    end

    it 'collects route helpers by whole words' do
      write('app/views/probe.html.erb', "<%= link_to 'x', login_path %> <%= account_url %>\n")

      expect(described_class.route_helpers(root: @root)).to include('login', 'account')
    end
  end
end
