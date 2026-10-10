# -*- encoding : utf-8 -*-
require 'spec_helper'

# The digest of the parse inputs — the mechanism that closes the control check
# "is a schema change visible while the source file stays the same".
# Incrementality rests on the file SHA, and without this digest a schema change
# invalidated nothing: the candidate layer and the column-to-model binding are
# already different while no re-parse happens. That is how the index insisted
# for a month that two tables were absent from two environments.
RSpec.describe Xref::Store do
  describe '.input_digest' do
    let(:known) { Set.new(%w[big_users login user_id]) }
    let(:models) { { 'BigUser' => 'big_users' } }
    let(:constants) { Set.new(%w[BigUser Pricing]) }

    def digest(known:, models:, constants:)
      described_class.input_digest(known: known, model_tables: models, app_constants: constants)
    end

    it 'is identical for identical inputs' do
      expect(digest(known: known, models: models, constants: constants))
        .to eq(digest(known: known, models: models, constants: constants))
    end

    it 'does not depend on order: sets and hashes arrive in different orders' do
      shuffled = Set.new(known.to_a.reverse)

      expect(digest(known: shuffled, models: models, constants: constants))
        .to eq(digest(known: known, models: models, constants: constants))
    end

    it 'changes on a new column in a schema' do
      grown = known + ['reset_code']

      expect(digest(known: grown, models: models, constants: constants))
        .not_to eq(digest(known: known, models: models, constants: constants))
    end

    it 'changes when a model moves to another table' do
      moved = { 'BigUser' => 'big_users_live' }

      expect(digest(known: known, models: moved, constants: constants))
        .not_to eq(digest(known: known, models: models, constants: constants))
    end

    it 'changes on a new application constant' do
      grown = constants + ['NewThing']

      expect(digest(known: known, models: models, constants: grown))
        .not_to eq(digest(known: known, models: models, constants: constants))
    end
  end

  # The habits of the tree are as much an INPUT of the parse as a schema: add a
  # name to `row_names` and there are more column reads with the files
  # unchanged. Without them in the digest an edit to the configuration caused no
  # re-parse, that is, the report went on counting by the previous habits while
  # looking fresh.
  describe '.input_digest about the habits' do
    def digest(idioms)
      described_class.input_digest(known: Set.new(%w[big_users]), model_tables: {},
                                   app_constants: Set.new, idioms: idioms)
    end

    it 'changes on a different set of habits' do
      expect(digest('повадки-1')).not_to eq(digest('повадки-2'))
    end

    it 'does not change while the habits are the same' do
      expect(digest('повадки-1')).to eq(digest('повадки-1'))
    end
  end

  # The parser digest is the same gate, and it breaks in the same dangerous
  # direction: narrowed silently means the parser was edited while the tree
  # answers from the old parse and looks fresh. So the narrowing is checked from
  # both sides.
  describe '.scanner_files' do
    let(:library) do
      %w[code_scanner.rb css.rb erb.rb js.rb markdown.rb nginx.rb shell.rb structured.rb
         store.rb verdicts.rb text_search.rb scan_plan.rb].map { |name| "lib/xref/#{name}" }
    end

    it 'takes only the participants of the parse' do
      expect(described_class.scanner_files(library))
        .to eq(%w[code_scanner.rb css.rb erb.rb js.rb markdown.rb nginx.rb shell.rb structured.rb]
                 .map { |name| "lib/xref/#{name}" })
    end

    # The list of participants must not be maintained by hand: add a parser and
    # the gate does not know about it, an edit to the parsing rules causes no
    # re-parse, and the report looks fresh. That is exactly how `css.rb` would
    # have gone uncounted as a participant. So the composition is checked
    # against the parsers `code_scanner` actually calls.
    it 'names as a participant every parser that code_scanner calls' do
      source = File.read(Xref.root.join('lib/xref/code_scanner.rb'))
      called = source.scan(/(?<![:\w.])(?:Xref::)?([A-Z][A-Za-z]+)\s*\./).flatten.uniq
                     .map { |const| "#{const.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}.rb" }
                     .select { |name| File.file?(Xref.root.join('lib/xref', name)) }
      library = Dir[Xref.root.join('lib/xref/*.rb').to_s]
      participants = described_class.scanner_files(library).map { |path| File.basename(path) }

      expect(called).not_to be_empty
      # The narrowing did happen (otherwise the check below passes over
      # nothing)…
      expect(participants.size).to be < library.size
      # …and every parser the scanner calls is in the narrowed composition.
      expect(participants).to include(*called)
    end

    # An edit to the store or to the verdict journal does not change the parse,
    # and there is no reason to pay 200 seconds of re-parsing for it.
    it 'does not depend on files that take no part in the parse' do
      without = library - ['lib/xref/verdicts.rb', 'lib/xref/store.rb']

      expect(described_class.scanner_files(without)).to eq(described_class.scanner_files(library))
    end

    # The main thing: it must not narrow by mistake. A parser was renamed — we
    # count over the whole directory, that is, we re-parse too much rather than
    # skip what is needed.
    it 'counts over the whole directory when a named participant goes missing' do
      renamed = library - ['lib/xref/nginx.rb'] + ['lib/xref/angie.rb']

      expect(described_class.scanner_files(renamed)).to eq(renamed.sort)
    end
  end

  # WHERE THE JAVASCRIPT STARTS IS A SETTING, NOT A LAYOUT. The seed for
  # reachability used to be one hardcoded path pattern (`app/javascript/packs/%`),
  # which is the Webpacker layout. A project on esbuild reported the result from
  # its own tree on 2026-10-10: nineteen JavaScript files, eleven import edges and
  # ZERO reachable from an entry point — while its two real roots were named in
  # `esbuild.config.mjs` and already sat in the index as facts (`js_entry`). So the
  # view seeds from the FACTS first and from a configured pattern second.
  describe 'the javascript entry points of v_entry_points' do
    let(:ddl) { described_class::DDL }

    it 'seed from the bundler facts rather than from one layout' do
      entry_block = ddl[/create view v_entry_points as.*?;/m]

      expect(entry_block).to include("e.kind = 'js_entry'")
    end

    it 'take the fallback pattern from the configuration' do
      expect(ddl).to include(Xref.sql_text_array(Xref.idioms[:js_entry_paths]))
      expect(Xref.idioms[:js_entry_paths]).to include('app/javascript/packs/%')
    end

    # The same for the service that runs WebSocket channels: its name belonged to
    # one application, and the code reachable only from a channel lies outside the
    # graph without it.
    it 'name the channel service by configuration too' do
      expect(ddl).to include(Xref.sql_text_array(Xref.idioms[:channel_service_units]))
    end

    # A configured value reaches SQL as a literal, so an apostrophe in it has to
    # be doubled: otherwise the string ends early and the view is created out of
    # whatever follows.
    it 'quote a configured value instead of gluing it in' do
      expect(Xref.sql_text_array(["a/%", "b'c"])).to eq("array['a/%', 'b''c']::text[]")
      expect(Xref.sql_text_array([])).to eq('array[]::text[]')
    end
  end
end
