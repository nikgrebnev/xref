# frozen_string_literal: true

require 'open3'

module Xref
  # Which views and partials actually get rendered — from production logs.
  #
  # A static graph cannot know this: 971 `render` calls assemble the partial
  # name from a variable. The application log, on the other hand, writes the
  # resolved template path, and `RAILS_MAX_THREADS=1` makes the attribution
  # exact: one worker, one thread, so the `Rendered` lines come strictly after
  # their own `Processing by`.
  #
  # The logs are parsed ON THE NODE: there are several gigabytes a day of them
  # and no reason to drag them here. What travels back is only the summary
  # "action|template|how many times".
  module ViewRuntime
    CONNECT_TIMEOUT = 25
    SSH_TIMEOUT = 900

    # Two different facts counted in one pass.
    #
    # `Rendered` is which template was drawn. `Processing by` is which ACTION
    # was requested at all, and those are not the same thing: an action that
    # answers with a redirect, with JSON or with a head renders nothing and by
    # the `Rendered` lines looks dead. Without the second counter "nobody
    # requested this route" was indistinguishable from "this route renders no
    # templates", and the site root `GET /` ended up among the dead.
    AWK = <<~AWK
      / Processing by / {
        i = index($0, "Processing by ");
        rest = substr($0, i + 14);
        j = index(rest, " as ");
        if (j > 0) rest = substr(rest, 1, j - 1);
        act = rest;
        a[act]++;
        next
      }
      / Rendered / {
        i = index($0, "Rendered ");
        rest = substr($0, i + 9);
        if (substr(rest, 1, 7) == "layout ") rest = substr(rest, 8);
        j = index(rest, " (");
        if (j > 0) rest = substr(rest, 1, j - 1);
        sub(/[ \\t]+$/, "", rest);
        if (rest == "") next;
        c[act "|" rest]++
      }
      END {
        for (k in a) print "A|" k "|" a[k];
        for (k in c) print "V|" k "|" c[k]
      }
    AWK

    class << self
      # => { views: [{action:, template:, hits:}], actions: [{action:, hits:}] }
      def collect(host, glob)
        out, err, status = Open3.capture3(
          'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
          host.to_s, 'sh', '-s',
          stdin_data: script(glob)
        )
        unless status.success?
          raise Error, "#{host}: ssh вернул #{status.exitstatus}: #{Xref.utf8(err).strip.lines.last(2).join(' ').strip}"
        end

        # A log line is the likeliest place for GENUINELY broken bytes: it
        # carries URLs and user agents, and changing the default encoding does
        # not help there — scrubbing does.
        parse(Xref.utf8(out))
      end

      # `theme_old/feedbacks/_feed_pic.erb` -> `app/views/theme_old/feedbacks/_feed_pic.erb`
      def template_path(template)
        return nil if template.blank? || template.include?(' ')

        "app/views/#{template}"
      end

      private

      def script(glob)
        <<~SH
          set -e
          files=$(ls #{glob} 2>/dev/null | head -400)
          if [ -z "$files" ]; then echo XREF_NO_LOGS; exit 0; fi
          # shellcheck disable=SC2086
          awk '#{AWK}' $files
        SH
      end

      def parse(out)
        # There are no logs for that day on the node — which is NOT "nothing was
        # rendered that day". The difference matters: what was collected earlier
        # must not be erased, and delete+insert with an empty list erases it.
        # That is exactly how the 2026-09-05 collection was lost on 2026-09-06.
        return { views: [], actions: [], no_logs: true } if out.include?('XREF_NO_LOGS')

        views = []
        actions = []
        out.each_line do |line|
          mark, rest = line.strip.split('|', 2)
          case mark
          when 'A'
            action, hits = rest.to_s.rpartition('|').then { |head, _, tail| [head, tail] }
            actions << { action: action.to_s, hits: hits.to_i } if action.present?
          when 'V'
            action, template, hits = rest.to_s.split('|', 3)
            views << { action: action.to_s, template: template, hits: hits.to_i } if template.present?
          end
        end
        { views: views, actions: actions, no_logs: false }
      end
    end
  end
end
