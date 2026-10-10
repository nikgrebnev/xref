# frozen_string_literal: true

require 'open3'

module Xref
  # Which environment keys are DEFINED in an environment.
  #
  # Needed for one check there is no other way to make: the code reads
  # `ENV['KEY']`, the environment does not define it, and `nil` arrives
  # SILENTLY — no error, no log line. That is how message intake on one
  # environment was never switched on at all.
  #
  # ONLY NAMES are collected. Values are neither read nor transferred: `sed`
  # cuts everything after `=` on the node, before anything is sent. This code
  # cannot change an environment — and must not: that is the owner's decision.
  module EnvKeys
    CONNECT_TIMEOUT = 25

    SCRIPT = <<~SH
      c=$(docker ps --format '{{.Names}}' | grep -E "$MATCH" | head -1)
      if [ -z "$c" ]; then echo "контейнер по образцу $MATCH не найден" >&2; exit 1; fi
      docker exec "$c" env | sed 's/=.*//' | sort -u
    SH

    class << self
      # => [names] (values are never transferred)
      def collect(host, container_match)
        out, err, status = Open3.capture3(
          'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
          host.to_s, "MATCH='#{container_match}' sh -s", stdin_data: SCRIPT
        )
        raise Error, "#{host}: #{err.strip.lines.last(1).join.strip}" unless status.success?

        Xref.utf8(out).split("\n").map(&:strip).select { |name| name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) }
      end
    end
  end
end
