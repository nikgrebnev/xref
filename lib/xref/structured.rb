# frozen_string_literal: true

require 'yaml'
require 'json'

module Xref
  # Parsing configuration files: yaml and json.
  #
  # How this differs from "read the file line by line". A configuration file is
  # a tree, and a question about it is asked with a key path
  # (`production.primary.host`), not with a word. But that is not the main
  # point: our `.yml` files contain ERB, and environment keys are read through
  # it — `config/database.yml`, `cable.yml`, `storage.yml`. While yaml went
  # unparsed those reads were invisible entirely, and the report "the code reads
  # a key the environment does not define" stayed silent about them.
  #
  # Hence the two-layer parse: first the Ruby inside the ERB tags is extracted
  # (and walked by the same pass that walks Ruby files), and only then the key
  # tree — over the text with the ERB cut out.
  module Structured
    # Depth and count: a configuration file can be a tree with thousands of
    # leaves (dictionaries, fixtures), and recording every leaf would bloat the
    # index the same way a text search is bloated.
    MAX_DEPTH = 4
    MAX_KEYS = 300
    MAX_BYTES = 2_000_000

    class << self
      # Text with the ERB removed, so that yaml parses. A marker is substituted
      # rather than emptiness: `host: <%= ENV['H'] %>` with no value stops being
      # a pair at all.
      def without_erb(source)
        source.gsub(Erb::ERB_TAG, 'xreferb')
      end

      # Key paths of the tree: ['production', 'production.primary', …].
      #
      # Leaf values do not enter the index, and that is not thrift: the value of
      # a setting is a password, an address or a key, and it has no place here.
      # ONLY names are recorded.
      def key_paths(tree, prefix = [], out = [], depth: MAX_DEPTH)
        return out if prefix.size >= depth || out.size >= MAX_KEYS

        case tree
        when Hash
          tree.each do |key, value|
            name = key.to_s
            next if name.empty?

            path = prefix + [name]
            # Without the duplicate check a homogeneous list yields the same
            # name once per entry walked.
            joined = path.join('.')
            out << joined unless out.include?(joined)
            key_paths(value, path, out, depth: depth)
          end
        when Array
          # A list in a configuration file is usually homogeneous entries, and
          # numbering them is pointless: their inner keys are the same.
          tree.first(3).each { |item| key_paths(item, prefix, out, depth: depth) }
        end
        out
      end

      def parse(path, source)
        return nil if source.bytesize > MAX_BYTES

        if path.end_with?('.json')
          JSON.parse(source)
        else
          YAML.safe_load(without_erb(source), aliases: true, permitted_classes: [Symbol, Date, Time])
        end
      rescue StandardError
        nil
      end

      # A file describing the composition of services. Kept apart from other
      # configuration because the questions are different: which image, which
      # environment keys, what is mounted, which port is published. Each of the
      # four has cost an incident once.
      def compose?(path, tree)
        return false unless tree.is_a?(Hash)

        File.basename(path).start_with?('docker-compose') ||
          (tree.key?('services') && tree['services'].is_a?(Hash))
      end

      # => [{ service:, image:, env: [], mounts: [], ports: [] }, …]
      def compose_services(tree)
        services = tree['services']
        return [] unless services.is_a?(Hash)

        services.map do |name, body|
          body = {} unless body.is_a?(Hash)
          { service: name.to_s, image: body['image'].to_s,
            env: env_names(body['environment']),
            mounts: Array(body['volumes']).filter_map { |v| mount_target(v) },
            ports: Array(body['ports']).map { |p| port_text(p) }.compact }
        end
      end

      # `environment` comes either as a `KEY=value` list or as a hash. ONLY
      # names are taken: in a service definition the value IS the secret.
      def env_names(environment)
        case environment
        when Hash then environment.keys.map(&:to_s)
        when Array then environment.map { |item| item.to_s.split('=', 2).first.to_s }
        else []
        end
      end

      # A mount: `source:target[:mode]`, or a hash form. The TARGET is needed,
      # and so is the source — the question "who mounts this path" is asked of
      # both.
      def mount_target(volume)
        case volume
        when String
          parts = volume.split(':')
          return nil if parts.size < 2

          "#{parts[0]}:#{parts[1]}"
        when Hash
          source = volume['source'] || volume[:source]
          target = volume['target'] || volume[:target]
          target ? "#{source}:#{target}" : nil
        end
      end

      def port_text(port)
        case port
        when String, Integer then port.to_s
        when Hash
          published = port['published'] || port[:published]
          target = port['target'] || port[:target]
          target ? "#{published}:#{target}" : nil
        end
      end
    end
  end
end
