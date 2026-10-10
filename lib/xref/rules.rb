# frozen_string_literal: true

module Xref
  # Architectural rules: an edge of the graph from `from` to `to` counts as a
  # violation.
  #
  # Split out of the task into its own unit for exactly one reason: so that the
  # latch is part of the spec run rather than something seen by eye in a report.
  # A rule nobody runs stops working silently — the report goes on printing.
  #
  # A latch rather than a zero: a rule with three hundred old violations stops
  # being read on the first day. `limit` is how many we tolerate today; when the
  # number grows, we shout.
  module Rules
    Result = Struct.new(:name, :why, :from, :to, :limit, :rows, keyword_init: true) do
      def count = rows.size
      def files = rows.map { |row| row['from_path'] }.uniq.size
      def grown? = count > limit
      def slack = limit - count

      def state
        return 'ВЫРОСЛО' if grown?
        return "меньше защёлки (#{limit}) — опустить в конфиге" if slack.positive?

        'в пределах защёлки'
      end
    end

    # A contract declared in prose, plus the latch that makes it fail.
    #
    # Taken from a second project (10.10.2026), where it produced the finding
    # this whole check exists for: "the contract is written down and nothing
    # enforces it". A rule with no latch holds until the first careless edit
    # and never says a word when it stops holding.
    #
    # Three states, and the middle one is the interesting one: the latch file
    # exists but does not even mention the subject of the contract — that is a
    # latch which passes while guarding nothing.
    Contract = Struct.new(:name, :doc, :latch, :token, :doc_exists, :latch_exists,
                          :token_files, keyword_init: true) do
      def state
        return 'НЕТ ЗАЩЁЛКИ: контракт объявлен текстом и ничем не закреплён' if latch.to_s.empty?
        return "ЗАЩЁЛКА ПОТЕРЯНА: файла #{latch} нет" unless latch_exists
        return "защёлка есть, но предмета (#{token}) не называет" if token.to_s.present? && token_files.zero?

        'защёлкнут'
      end

      def broken?
        latch.to_s.empty? || !latch_exists || (token.to_s.present? && token_files.zero?)
      end
    end

    class << self
      # => [Result], one per rule from the configuration
      def check(rules = nil, conn: Store.conn)
        Array(rules || Xref.config[:rules]).map do |rule|
          rows = conn.select_all(<<~SQL.squish).to_a
            select e.from_path, e.to_path, e.kind
            from v_code_edges e
            where e.from_path like #{conn.quote(rule[:from].to_s)}
              and e.to_path like #{conn.quote(rule[:to].to_s)}
            order by e.from_path, e.to_path
          SQL
          Result.new(name: rule[:name].to_s, why: rule[:why].to_s.gsub(/\s+/, ' ').strip,
                     from: rule[:from].to_s, to: rule[:to].to_s,
                     limit: rule[:limit].to_i, rows: rows)
        end
      end

      # Is there anything to check against at all: an empty graph yields zero
      # violations for every rule, and that is NOT "all is well" but "nobody
      # looked".
      def ready?(conn: Store.conn)
        conn.select_value('select 1 from v_code_edges limit 1').present?
      end

      # => [Contract], one per entry of the `contracts:` config section.
      def contracts(list = nil, conn: Store.conn)
        Array(list || Xref.config[:contracts]).map do |item|
          latch = item[:latch].to_s
          token = item[:token].to_s
          Contract.new(name: item[:name].to_s, doc: item[:doc].to_s, latch: latch, token: token,
                       doc_exists: indexed?(item[:doc], conn: conn),
                       latch_exists: indexed?(latch, conn: conn),
                       token_files: token_files(latch, token))
        end
      end

      private

      # The subject of a contract is searched AS TEXT inside the latch file, not
      # through the index: the index only records `token` refs for names it knows
      # from a schema, and a contract's subject is `structure.sql`, `routes-v1.md`
      # or a class name. Checking those through the index answered "does not
      # mention it" for every contract at once.
      def token_files(latch, token)
        return 0 if latch.empty? || token.empty?

        TextSearch.lines(token, fixed: true, globs: [latch]).map(&:path).uniq.size
      rescue Error
        0
      end

      # Existence is asked of the INDEX, not of the filesystem: a path outside
      # the indexed tree is not a file of this project, and a contract pointing
      # there is broken even when something with that name happens to exist.
      def indexed?(pattern, conn: Store.conn)
        return false if pattern.to_s.empty?

        conn.select_value(
          "select 1 from code_files where path like #{conn.quote(pattern.to_s)} limit 1"
        ).present?
      end
    end
  end
end
