# frozen_string_literal: true

module Xref
  # What lives inside jsonb columns.
  #
  # A jsonb column has no schema — it only has whatever was actually written
  # into it. So the keys are not derived from a structure but sampled: a few
  # thousand rows per column, `jsonb_object_keys` over them.
  #
  # Sampled from a replica rather than from production: the set of keys does not
  # differ, and there is no reason to make production work for this.
  module JsonKeys
    class << self
      # => [{table_name:, column_name:, key:, hits:}]
      def collect(source_name, rows:, statement_timeout:)
        columns = jsonb_columns(source_name)
        return [] if columns.empty?

        out = SchemaSource.new(source_name).run(script(columns, rows, statement_timeout))
        parse(out)
      end

      def jsonb_columns(source_name)
        Store.conn.select_rows(<<~SQL.squish)
          select table_name, column_name from v_columns
          where source = #{Store.conn.quote(source_name.to_s)} and data_type = 'jsonb'
          order by table_name, column_name
        SQL
      end

      private

      # The queries go as separate statements rather than as one UNION ALL: in
      # psql without ON_ERROR_STOP a single failed or hanging statement does not
      # take the others down with it. And there is something to fail on — a
      # column may hold an array or a scalar, and then jsonb_object_keys
      # complains.
      def script(columns, rows, statement_timeout)
        header = "set statement_timeout = '#{statement_timeout}';\n"
        header + columns.map do |table, column|
          <<~SQL.squish
            select #{quote_literal(table)}, #{quote_literal(column)}, k, count(*)
            from (select jsonb_object_keys(c) k from (
                    select #{quote_ident(column)} c from #{quote_ident(table)}
                    where #{quote_ident(column)} is not null
                      and jsonb_typeof(#{quote_ident(column)}) = 'object'
                    limit #{rows.to_i}) s) t
            group by 1, 2, 3;
          SQL
        end.join("\n")
      end

      def parse(out)
        out.to_s.each_line.filter_map do |line|
          table, column, key, hits = line.strip.split('|', 4)
          next if table.blank? || key.blank?

          { table_name: table, column_name: column, key: key, hits: hits.to_i }
        end
      end

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quote_literal(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end
end
