# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'open3'

# The encoding of external bytes is a class of error that kills THE WHOLE
# COMMAND.
#
# Without `LANG` (a non-interactive shell, cron, a script) Ruby assumes the
# locale is US-ASCII, and the first non-Latin letter — out of an external
# command's output, out of ENV or out of a file — brings down `split`, `match?`
# or `format`. The report is then not empty but ABSENT, and that reads as "the
# tool is broken": on 2026-10-09 `bin/xref find` with a non-Latin pattern and
# `bin/xref calls` silently did not work that way.
#
# An application covers this in `config/environment.rb`, but index queries do not
# load Rails — so they never get the setting. What is checked is therefore not a
# setting but THE BEHAVIOUR of a run with no locale.
RSpec.describe 'кодировка внешних байтов' do
  describe 'Xref.utf8' do
    it 're-tags bytes that arrived with a foreign label' do
      bytes = 'перевод'.dup.force_encoding(Encoding::US_ASCII)

      expect(bytes.valid_encoding?).to be(false)
      expect(Xref.utf8(bytes)).to eq('перевод')
      expect(Xref.utf8(bytes).encoding).to eq(Encoding::UTF_8)
    end

    # Changing the label fixes only the label. Genuine garbage in the bytes (a
    # broken file, a log line with a truncated character) remains, and `match?`
    # over it dies — so the second action is scrubbing rather than
    # `force_encoding` alone.
    it 'replaces genuine garbage without losing the hit' do
      broken = "начало\xC3\x28конец".dup.force_encoding(Encoding::UTF_8)

      expect(broken.valid_encoding?).to be(false)
      expect(Xref.utf8(broken)).to include('начало', 'конец')
      expect(Xref.utf8(broken).valid_encoding?).to be(true)
    end

    it 'turns nothing into an empty string rather than failing' do
      expect(Xref.utf8(nil)).to eq('')
    end
  end

  # WHAT IS NOT CHECKED HERE, and saying so is more honest than silence. The
  # second layer of protection — `xref_arg` in the tasks — is meant for a system
  # where `C.UTF-8` is unknown and the re-exec did not help. Such a locale cannot
  # be simulated on this machine: Ruby understands `C.UTF-8` and gets fixed on
  # the very first pass. So the second layer is checked as a unit (through
  # `Xref.utf8` above) rather than end to end.

  # An end-to-end check: a run WITH NO locale and with a non-Latin argument. The
  # task chosen is one that needs no database (`xref:locale`) — when a command
  # dies on an encoding it dies before any query. Inside it is exactly the form
  # `find` died on: non-Latin text in a `format` next to a value from ENV.
  describe 'bin/xref-run with no locale' do
    def run_without_locale(*args)
      Open3.capture3(
        { 'LANG' => nil, 'LC_ALL' => nil, 'LC_CTYPE' => nil },
        RbConfig.ruby, 'bin/xref-run', *args, chdir: Xref.root.to_s
      )
    end

    it 'reads a non-Latin argument and prints it in full' do
      out, err, status = run_without_locale('xref:locale', 'NAME=перевод')
      output = "#{out}#{err}"

      expect(output).not_to match(/invalid byte sequence|Encoding::CompatibilityError/),
                            "запуск без локали упал на кодировке:\n#{output[0, 600]}"
      expect(status.exitstatus).to eq(0)
      # Seven CHARACTERS rather than bytes: with a broken encoding there would
      # have been fourteen.
      expect(out).to include('«перевод» прочитан целиком: 7 знаков')
      expect(out).to include('кодировки в порядке')
    end
  end
end
