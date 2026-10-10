# frozen_string_literal: true

module Xref
  # Which migrations are APPLIED in each environment.
  #
  # Environment schemas do not drift apart by themselves: the drift almost
  # always has a cause recorded in `schema_migrations`. The check costs one
  # query and answers a question otherwise discovered halfway through a deploy:
  # "is that migration applied over there?"
  #
  # Data, not schema: a schema snapshot holds tables and columns, while the set
  # of applied migrations is the content of a table and has to be asked for
  # separately.
  module Migrations
    # Short numbers are a Rails 2 legacy (`15`, `16`, …): there are no files for
    # them in the tree and there cannot be, so they are kept out of the
    # comparison against the repository.
    TIMESTAMP = /\A\d{14}\z/

    class << self
      # => [versions], or nil if asking failed
      def applied(source)
        out = SchemaSource.new(source.to_s).run('select version from schema_migrations')
        versions = out.to_s.split("\n").map(&:strip).reject(&:empty?)
        versions.presence
      rescue StandardError
        nil
      end

      # Migration versions present in the tree: the file name starts with one.
      def in_repo(root: Xref.root)
        Dir[File.join(root.to_s, 'db/migrate/*.rb')]
          .map { |path| File.basename(path).split('_').first }
          .select { |version| version.match?(TIMESTAMP) }
          .sort
      end

      # What is compared: applied timestamps against the files of the tree.
      # Short numbers and "applied but no file" are different findings and must
      # not be mixed.
      def compare(applied_by_source, repo)
        applied_by_source.to_h do |source, versions|
          stamped = Array(versions).select { |version| version.match?(TIMESTAMP) }
          [source, { applied: stamped.size,
                     legacy: Array(versions).size - stamped.size,
                     missing: (repo - stamped).sort,
                     extra: (stamped - repo).sort }]
        end
      end
    end
  end
end
