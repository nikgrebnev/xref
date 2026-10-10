# frozen_string_literal: true

require 'yaml'

module Xref
  # What the translation store holds — read from the files, BYPASSING I18n.
  #
  # Asking `I18n.t` is pointless: a project with fallbacks enabled will quietly
  # serve English wherever a translation is missing, so the check "is a
  # translation returned" is green always. Hence the raw files are read and the
  # keys counted per language here.
  #
  # Where to read is a habit of the tree, not a constant: `locale_dirs` in
  # `config/xref.yml`. In this tree there are two such places — the shared
  # legacy store and a newer one with a file per task; both are loaded by a
  # single `i18n.load_path`, so for an answer they are equal, but knowing which
  # file a key came from is useful, because only one of them gets edited.
  module Locales
    class << self
      # => [{ lang:, key:, file: }, …]
      def collect(root: Xref.root)
        Array(Xref.idioms[:locale_dirs]).flat_map do |dir|
          Dir[File.join(root.to_s, dir.to_s, '**/*.yml')].sort.flat_map { |path| from_file(path, root: root) }
        end
      end

      def from_file(path, root: Xref.root)
        tree = YAML.safe_load(File.read(path), aliases: true)
        return [] unless tree.is_a?(Hash)

        relative = path.sub(%r{\A#{Regexp.escape(root.to_s)}/?}, '')
        tree.flat_map do |lang, subtree|
          flatten(subtree).map { |key| { lang: lang.to_s, key: key, file: relative } }
        end
      rescue StandardError
        # A broken or unreadable file is no reason to lose the rest. Staying
        # silent about it is not allowed either, so it comes back as its own row.
        [{ lang: '?', key: '', file: path.to_s }]
      end

      # Flat dotted keys. An array is a leaf, and `one`/`other` inside plural
      # forms are not keys: otherwise every such key splits into five and the
      # comparison against the code breaks.
      def flatten(node, prefix = nil)
        return [prefix].compact unless node.is_a?(Hash)

        node.flat_map do |key, value|
          nested = [prefix, key].compact.join('.')
          if value.is_a?(Hash) && !plural?(value)
            flatten(value, nested)
          else
            [nested]
          end
        end
      end

      PLURAL_KEYS = %w[zero one two few many other].freeze
      def plural?(hash)
        keys = hash.keys.map(&:to_s)
        keys.any? && (keys - PLURAL_KEYS).empty?
      end
    end
  end
end
