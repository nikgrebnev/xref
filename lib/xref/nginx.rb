# frozen_string_literal: true

module Xref
  # Parsing the front-end configuration (nginx/angie).
  #
  # This is the most expensive of the newer parses, and its price is known from
  # incidents. All four of them are visible exactly here and nowhere else:
  #
  #   * an UNANCHORED virtual-host regexp swallowed two production addresses;
  #   * `rewrite … last` re-selects the location FROM SCRATCH, so the
  #     `limit_conn`/`add_header` of the first location never apply — and fixing
  #     anything in the application is useless meanwhile;
  #   * `http_404` in `proxy_next_upstream` doubles the load on every honest 404;
  #   * an own `add_header Cache-Control` does NOT replace an upstream one
  #     without `proxy_hide_header`.
  #
  # The parse is structural: blocks, directives, nesting. It is not a full nginx
  # parser (nested `map`, `if`, variables) but a parse of the places where the
  # markup is unambiguous — and everything ambiguous stays silent instead of
  # guessing.
  module Nginx
    # The directives people ask about. The rest are not recorded: "the config
    # has gzip_types in it" answers nothing.
    WANTED = %w[
      server_name listen location root alias index try_files include
      proxy_pass fastcgi_pass uwsgi_pass grpc_pass
      rewrite return error_page
      add_header proxy_hide_header proxy_set_header expires
      proxy_next_upstream limit_conn limit_req limit_conn_zone limit_req_zone
      upstream server access_log error_log ssl_certificate
    ].freeze

    BLOCK_OPEN = /\A(?<name>\w+)(?<args>[^{};]*)\{\s*\z/
    DIRECTIVE = /\A(?<name>\w+)(?<args>[^{};]*);\s*\z/

    Element = Struct.new(:kind, :name, :args, :line, :scope, keyword_init: true)

    class << self
      # => [Element, …]. `scope` is the nesting path ("http > server > location /img").
      def elements(source)
        out = []
        stack = []

        source.each_line.with_index(1) do |raw, line|
          row = raw.sub(/#.*\z/, '').strip
          next if row.empty?

          if row == '}'
            stack.pop
            next
          end

          if (match = row.match(BLOCK_OPEN))
            name = match[:name]
            args = match[:args].to_s.strip
            stack.push(args.empty? ? name : "#{name} #{args}")
            out << Element.new(kind: 'block', name: name, args: args, line: line,
                               scope: stack[0..-2].join(' > '))
            next
          end

          next unless (match = row.match(DIRECTIVE))

          name = match[:name]
          next unless WANTED.include?(name)

          out << Element.new(kind: 'directive', name: name, args: match[:args].to_s.strip,
                             line: line, scope: stack.join(' > '))
        end
        out
      end

      # A virtual-host regexp with no anchors. The most expensive finding of
      # this parse: such a name matches SOMEBODY ELSE'S address, and the host
      # starts answering for it.
      def unanchored_server_name?(args)
        args.to_s.split(/\s+/).any? do |name|
          next false unless name.start_with?('~')

          body = name.delete_prefix('~').delete_prefix('*')
          !body.start_with?('^') || !body.end_with?('$')
        end
      end

      # `rewrite … last` inside a location: location selection starts FROM
      # SCRATCH, and everything that stood in this location (limits, headers)
      # will not apply.
      def rewrite_restarts?(args)
        args.to_s.match?(/\blast\s*\z/)
      end

      # `http_404` among the reasons to move to the next upstream: every honest
      # 404 turns into as many requests as there are nodes in the group.
      def next_upstream_doubles?(args)
        args.to_s.split(/\s+/).include?('http_404')
      end
    end
  end
end
