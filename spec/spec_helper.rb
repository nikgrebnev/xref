# frozen_string_literal: true

# The spec helper of the standalone installation.
#
# The engine is loaded exactly the way `bin/xref-run` loads it — without the
# application being indexed and without Rails. That is not a convenience: half
# the point of these specs is that the parsers work on their own, and a helper
# that pulled in a framework would hide a dependency the tool must not have.
#
# This file is the only one that differs between this repository and the tree the
# engine is grown in (there `require 'rails_helper'` stands instead, because the
# specs run inside the application's suite). Everything else — every parser,
# every task, every example — is byte for byte the same.

ENV['XREF_DATABASE_URL'] ||= 'postgresql:///xref_spec'

require 'bundler/setup'
require 'active_record'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/filters'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/hash/keys'
require 'set'
require 'pg'
require 'rspec'

home = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(home, 'lib')
require 'xref'
Dir[File.join(home, 'lib/xref/*.rb')].sort.each { |file| require file }

# TWO SPECS NEED THE INDEX DATABASE, and the rest do not. They are named here
# rather than tagged in the spec files, because the spec files are shared with
# the tree the engine comes from and must not acquire anything of this
# repository's own.
#
# Without a database those two are SKIPPED rather than failed — but the skip says
# what to do, because a skipped check is still an unanswered question.
NEEDS_INDEX_DATABASE = %w[components_spec rules_spec].freeze

# The probe applies the schema as well, and that is the point: two of the specs
# ask about views (`v_code_edges`) and tables (`code_files`), and an empty
# database answers neither. `migrate!` is idempotent — it is what every command
# of the tool runs anyway.
def index_database_available?
  Xref::Store.migrate!
  Xref::Store.conn.select_value('select 1').to_i == 1
rescue StandardError
  false
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  available = nil
  config.before do |example|
    next unless NEEDS_INDEX_DATABASE.any? { |name| example.metadata[:file_path].to_s.include?(name) }

    available = index_database_available? if available.nil?
    next if available

    skip "the index database is unavailable (#{ENV.fetch('XREF_DATABASE_URL', nil)}): " \
         'create it with `createdb xref_spec`, or point XREF_DATABASE_URL elsewhere'
  end
end
