# frozen_string_literal: true

# The tool's own bundle. It has nothing to do with the Gemfile of the project
# being indexed, and it must not: xref is not part of your product, and its
# dependencies have no business in your dependency list.
#
# Installed into ./vendor/bundle:
#
#   bundle config set --local path vendor/bundle
#   bundle install
#
source 'https://rubygems.org'

ruby '>= 3.2'

# ActiveRecord is here for two things only: a connection pool of its own and
# correct quoting. The application being indexed is never loaded — the reports
# are SQL against a local database.
gem 'activerecord', '>= 7.0'
gem 'pg', '~> 1.5'
gem 'rake', '~> 13.0'

# The one real dependency of the tool: the database's own SQL parser. Without it
# the index still works — it is simply poorer, and it says so: every query goes
# into the blind spots instead of yielding tables and columns.
gem 'pg_query', '>= 5.0'

# Ruby parsing. Prism ships with Ruby 3.4; the gem is here for 3.2 and 3.3.
gem 'prism', '>= 0.30'

group :development, :test do
  gem 'rspec', '~> 3.13'
end
