# frozen_string_literal: true

require 'open3'
require 'shellwords'

module Xref
  # Where code runs: the set of runit services is taken from the live
  # containers, not from an inventory file kept by hand.
  #
  # Hand-kept inventories lag: on 2026-08-15 a group of robots had been running
  # on one environment for a month while the stack file claimed otherwise. A
  # live `ls /etc/service` does not lie.
  module RunPlaces
    CONNECT_TIMEOUT = 20

    # `export ROBOT_COMMAND='bundle exec rake robots:digest NUM=…'`
    COMMAND_LINE = /(?:ROBOT_COMMAND|RUNTIME_SERVICE_COMMAND)=['"]([^'"]*)['"]/
    RAKE_TASK = /\brake\s+([a-z0-9_]+(?::[a-z0-9_]+)+)/

    class << self
      # => [{unit:, command:, rake_task:}]
      def collect(place, cfg)
        out, err, status = Open3.capture3(
          'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
          cfg[:ssh_host].to_s, 'sh', '-s',
          stdin_data: script(cfg)
        )
        unless status.success?
          raise Error, "#{place}: #{cfg[:ssh_host]} вернул #{status.exitstatus}: #{err.strip.lines.last(2).join(' ').strip}"
        end
        out = Xref.utf8(out)
        raise Error, "#{place}: контейнер по образцу #{cfg[:container_match]} не найден" if out.include?('XREF_NO_CONTAINER')

        parse(out)
      end

      private

      def script(cfg)
        match = Shellwords.escape(cfg[:container_match].to_s)
        <<~SH
          set -e
          c=$(docker ps --format '{{.Names}}' | grep -E #{match} | head -1)
          if [ -z "$c" ]; then echo XREF_NO_CONTAINER; exit 0; fi
          for s in $(docker exec "$c" ls /etc/service 2>/dev/null); do
            echo "== $s"
            docker exec "$c" cat "/etc/service/$s/run" 2>/dev/null || true
          done
        SH
      end

      def parse(out)
        units = []
        current = nil

        out.each_line do |line|
          if line.start_with?('== ')
            current = { unit: line[3..].strip, command: nil, rake_task: nil }
            units << current
            next
          end
          next if current.nil? || current[:command]

          match = line.match(COMMAND_LINE)
          next if match.nil?

          current[:command] = match[1]
          current[:rake_task] = match[1][RAKE_TASK, 1]
        end

        units.reject { |u| u[:unit].blank? }
      end
    end
  end
end
