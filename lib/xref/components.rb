# frozen_string_literal: true

module Xref
  # The component model: who is who in the tree, and who is allowed to depend on
  # whom.
  #
  # It exists for the thing path patterns alone cannot show: one huge "shared"
  # component absorbs several responsibilities and hides the boundaries between
  # them. So the report speaks not only about layer-order violations but about
  # the model itself — overlapping patterns, the unmapped mass, a component that
  # talks to almost everyone.
  #
  # Reviewing the model COMES BEFORE forbidding violations: forbidding by a
  # wrong mapping is worse than not forbidding at all.
  module Components
    # Layer: a dependency is allowed downwards and sideways, never upwards.
    #
    # The order is derived from how this tree actually works, not from general
    # words: a controller DEPENDS on a template (it renders it), which is why
    # `ui` sits below `api` rather than above it. The first version of the order
    # was inverted and declared 3,216 ordinary renders to be violations — the
    # model has to be checked before anything is forbidden by it.
    RANKS = { 'api' => 1, 'ui' => 2, 'service' => 3, 'domain' => 4,
              'shared' => 5, 'infra' => 5, 'test' => 9 }.freeze

    # `shared` is common housekeeping: everyone depends on it and that is not a
    # violation. Nobody depends on `test` or on `infra`.
    ALWAYS_ALLOWED_TARGET = %w[shared].freeze

    # The threshold for a real cycle: the weak side is at least nine edges and
    # at least a tenth of the strong one. Without a threshold the report lists
    # fourteen pairs, thirteen of which are one or two accidental references.
    CYCLE_MIN_EDGES = 9
    CYCLE_MIN_SHARE = 0.1

    Component = Struct.new(:name, :role, :paths, :except, keyword_init: true) do
      def rank = RANKS[role.to_s] || 9

      # `except` is needed because the patterns otherwise overlap: `lib/%`
      # swallows `lib/tasks/%`, and 42 files ended up in two components at once.
      def condition(conn, column = 'path')
        include_part = paths.map { |pattern| "#{column} like #{conn.quote(pattern)}" }.join(' or ')
        return "(#{include_part})" if Array(except).empty?

        exclude_part = Array(except).map { |pattern| "#{column} not like #{conn.quote(pattern)}" }.join(' and ')
        "((#{include_part}) and #{exclude_part})"
      end
    end

    class << self
      def all
        Array(Xref.config[:components]).map do |item|
          Component.new(name: item[:name].to_s, role: item[:role].to_s,
                        paths: Array(item[:paths]).map(&:to_s),
                        except: Array(item[:except]).map(&:to_s))
        end
      end

      # File -> names of the components it belongs to. More than one is a
      # mapping error, and it has to be seen before anything is forbidden by it.
      def membership(conn: Store.conn)
        found = Hash.new { |hash, key| hash[key] = [] }
        all.each do |component|
          conn.select_values("select path from code_files where #{component.condition(conn)}")
              .each { |path| found[path] << component.name }
        end
        found
      end

      # Edges between components: how many and in which direction. Upwards
      # across layers is a violation.
      def edges(conn: Store.conn)
        components = all
        return [] if components.empty?

        cases = components.each_with_index.map do |component, index|
          "when #{component.condition(conn, 'e.from_path')} then #{index}"
        end
        targets = components.each_with_index.map do |component, index|
          "when #{component.condition(conn, 'e.to_path')} then #{index}"
        end

        rows = conn.select_all(<<~SQL.squish).to_a
          select (case #{cases.join(' ')} else -1 end) as from_index,
                 (case #{targets.join(' ')} else -1 end) as to_index,
                 count(*)::int as edges, count(distinct e.from_path)::int as files
          from v_code_edges e group by 1, 2
        SQL

        rows.filter_map do |row|
          source = components[row['from_index'].to_i]
          target = components[row['to_index'].to_i]
          next if source.nil? || target.nil? || source.name == target.name

          { from: source, to: target, edges: row['edges'], files: row['files'],
            upward: upward?(source, target) }
        end
      end

      # A dependency in BOTH directions between two components. This is not a
      # layer-order violation but a sign that one of the two has absorbed two
      # responsibilities: no ordering will separate a pair that calls into each
      # other. This is what the model is for — path patterns cannot show it.
      def cycles(conn: Store.conn)
        found = edges(conn: conn)
        index = found.to_h { |edge| [[edge[:from].name, edge[:to].name], edge] }
        pairs = []
        index.each do |(from, to), edge|
          back = index[[to, from]]
          next if back.nil? || pairs.any? { |pair| pair[:names].sort == [from, to].sort }

          weak = [edge[:edges], back[:edges]].min
          strong = [edge[:edges], back[:edges]].max
          # One back-reference against a hundred forward ones is not "absorbed
          # two responsibilities" but a few accidental references, and it is
          # fixed one by one. A real cycle is when both sides are substantial.
          pairs << { names: [from, to], forward: edge, backward: back,
                     strong: weak >= CYCLE_MIN_EDGES && weak >= strong * CYCLE_MIN_SHARE }
        end
        pairs.sort_by { |pair| -(pair[:forward][:edges] + pair[:backward][:edges]) }
      end

      def upward?(source, target)
        return false if source.role == 'test'
        # "Nobody depends on tests" cannot be expressed by rank: a test has the
        # lowest rank, and comparing ranks let such a dependency through. Caught
        # by a spec.
        return true if target.role == 'test'
        return false if ALWAYS_ALLOWED_TARGET.include?(target.role)

        target.rank < source.rank
      end
    end
  end
end
