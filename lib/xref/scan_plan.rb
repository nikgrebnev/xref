# frozen_string_literal: true

module Xref
  # Which files have to be parsed again — and which ones need a SHA computed to
  # find that out.
  #
  # Split out of the task into its own unit for one reason: this is a GATE, and
  # it breaks in the dangerous direction. If the gate stops letting a changed
  # file through, the index answers from stale content while looking fresh —
  # exactly the failure that once had the index insisting for a month that two
  # tables were absent from two environments. So the decision here is pure, with
  # no filesystem in it, and it has a spec: the spec shows both that nothing
  # extra is hashed and that nothing changed is skipped.
  #
  # Why a gate at all: the catch-up computed the SHA of all 8,326 files on EVERY
  # command — 1.5 s out of the four that `bin/xref where` took, with zero edits
  # in the tree. Walking the same files with `stat` costs 0.018 s.
  #
  # Modification time is NOT treated as proof in either direction: if it
  # matches, the previous SHA is trusted; if it differs, the SHA is recomputed
  # and compared. A file rewritten with identical content is not re-parsed.
  module ScanPlan
    Plan = Struct.new(:current, :mtimes, :changed, :removed, :hashed, keyword_init: true)

    class << self
      # paths      — paths under the index (already filtered by extension)
      # stored     — { path => [sha, inputs_sha, mtime] } from the previous parse
      # inputs_sha — digest of the parse inputs: changed means parse everything
      # full       — forced full parse (FULL=1)
      # mtime:     — ->(path) { modification time, or nil if the file is gone }
      # digest:    — ->(path) { SHA of the contents }
      def call(paths, stored:, inputs_sha:, full: false, mtime:, digest:)
        current = {}
        mtimes = {}
        hashed = []

        paths.each do |path|
          stamp_time = mtime.call(path)
          next if stamp_time.nil?

          mtimes[path] = stamp_time
          sha, inputs, seen = stored[path]
          if !full && seen && seen == stamp_time && inputs == inputs_sha
            current[path] = sha
          else
            hashed << path
            current[path] = digest.call(path)
          end
        end

        changed = if full
                    current
                  else
                    current.reject do |path, sha|
                      stamp = stored[path]
                      stamp && stamp[0] == sha && stamp[1] == inputs_sha
                    end
                  end

        Plan.new(current: current, mtimes: mtimes, changed: changed,
                 removed: stored.keys - current.keys, hashed: hashed)
      end
    end
  end
end
