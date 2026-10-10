# frozen_string_literal: true

module Xref
  # Parsing JavaScript — the last whole language the index could not see.
  #
  # 431 files sat in the index and yielded nothing but word matches. Because of
  # that the reachability graph broke off at `app/javascript`, and the chain
  # "template → Stimulus controller → its method" did not exist at all, even
  # though `data-controller` appears in 1,022 templates.
  #
  # We have no JavaScript parser of our own, and writing one for these
  # questions is not worth it. The parse takes the places where the markup is
  # unambiguous: a module declaration, a class, Stimulus declarations
  # (`static targets/values/classes`), method definitions inside a class and the
  # registration of a controller. Everything ambiguous stays silent.
  #
  # The tree is on CommonJS (102 files with `require`, 110 with
  # `module.exports`) and in places on ESM (12 files). Both are parsed: skipping
  # one means breaking the graph at an arbitrary point.
  module Js
    # `require('./x')` and `import … from './x'`, including `import('./x')`.
    REQUIRE = /\brequire\(\s*(?<quote>['"])(?<path>[^'"\n]+)\k<quote>\s*\)/
    IMPORT_FROM = /\bfrom\s+(?<quote>['"])(?<path>[^'"\n]+)\k<quote>/
    IMPORT_BARE = /^\s*import\s+(?<quote>['"])(?<path>[^'"\n]+)\k<quote>/
    DYNAMIC_IMPORT = /\bimport\(\s*(?<quote>['"])(?<path>[^'"\n]+)\k<quote>\s*\)/
    # TOP-LEVEL FUNCTIONS. Class methods were known to the index, these were
    # not: there are about five hundred of them in this tree, which means half
    # the code could not answer the question "who calls this".
    FUNCTION = /^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s+(?<name>[A-Za-z_$][\w$]*)/
    ARROW = /^\s*(?:export\s+)?(?:const|let|var)\s+(?<name>[A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>/
    GLOBAL_FUNCTION = /^\s*window\.(?<name>[A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?function/
    # A call site: `name(`. A name is a poor key (just as in Ruby), so this is
    # a HOOK rather than a fact, and the report is obliged to say so.
    # A dot before the name means a method access (we do not resolve receivers),
    # while THREE dots mean a spread: `...errorMessageOption()` is an ordinary
    # call. Without the second branch the very last verified finding turned out
    # to be false.
    CALL = /(?:(?<![.\w$])|(?<=\.\.\.))(?<name>[A-Za-z_$][\w$]*)\s*\(/
    # Import bindings: `import $ from 'jquery'`, `import { a, b } from 'pkg'`.
    # They are how calls INTO A LIBRARY are counted — there is no need to go
    # inside a library, but there is a need to know whether it is still called.
    BINDINGS = /^\s*import\s+(?<body>[^'"]+?)\s+from\s+(?<quote>['"])(?<path>[^'"\n]+)\k<quote>/
    # Names whose call says nothing about the tree.
    NOT_A_CALL = %w[
      if for while switch catch return typeof function new delete await yield
      Promise Array Object String Number Boolean Error Map Set JSON Math Date
      console require import super this constructor parseInt parseFloat
    ].freeze

    # `module.exports = Name`, `module.exports = { A, B }`,
    # `module.exports.name =`, `export default`, `export class`,
    # `export function`, `export const`.
    EXPORTS = /^\s*module\.exports(?:\.(?<name>\w+))?\s*=\s*(?<value>.*)$/
    EXPORT_ESM = /^\s*export\s+(?:default\s+)?(?:class|function|const|let|var)\s+(?<name>\w+)/

    # A class. `extends Controller` is the sign of a Stimulus controller; such
    # a class also comes anonymous
    # (`module.exports = class extends Controller {`).
    CLASS = /\bclass\s+(?<name>\w+)?\s*extends\s+(?<parent>[\w.]+)/
    # Stimulus declarations.
    # A list declaration comes in three forms, and missing any of them yields a
    # false finding "the target is not declared": here seven controllers out of
    # twenty-one declare targets with a GETTER, and one with a list spread over
    # two lines.
    STATIC_LIST = /^\s*static\s+(?<kind>targets|classes|outlets)\s*=\s*\[(?<body>[^\]]*)\]?/
    STATIC_GETTER = /^\s*static\s+get\s+(?<kind>targets|classes|outlets)\s*\(\s*\)/
    LIST_RETURN = /^\s*return\s*\[(?<body>[^\]]*)\]?/
    STATIC_VALUES = /^\s*static\s+values\s*=\s*\{/
    # The registration call: the only place where a name from a template is
    # linked to a class.
    REGISTER = /\.register\(\s*(?<quote>['"])(?<identifier>[^'"\n]+)\k<quote>\s*,\s*(?<klass>[\w.]+)/
    # A method definition inside a class: `name() {`, `async name() {`,
    # `get name() {`.
    # TypeScript: between `)` and `{` there is a return type
    # (`choose(event: Event): void {`), before the name there are access
    # modifiers, and after the name there may be generics. Without this, in a
    # TypeScript project NOT A SINGLE controller method was found, and the check
    # "an action from the template against a method" answered "NO SUCH METHOD"
    # for every existing one (a second project, 2026-10-09).
    METHOD = /^\s{2,}(?:async\s+|static\s+|get\s+|set\s+|public\s+|private\s+|protected\s+|override\s+)*(?<name>[A-Za-z_$][\w$]*)(?:<[^>(]*>)?\s*\([^)]*\)\s*(?::[^{]*)?\{/
    # Build roots are named in the bundler config, not only in `package.json`:
    # `entryPoints: ["app/javascript/application.ts"]`.
    ENTRY_POINTS = /entryPoints\s*[:=]\s*[\[{]/
    # A path assembled from parts:
    # `path.join(root, 'app', 'javascript', 'x.css')`. That is how stylesheet
    # entry points are named in the build config, and they exist nowhere as a
    # whole string — a search for `'app/javascript/...'` does not find them,
    # while the file is alive. Verified by hand: one such file was listed as
    # "needed by nobody".
    PATH_JOIN = /path\.join\(\s*(?<body>[^)]*)\)/
    # Words that are not methods even though they look like one.
    NOT_METHOD = %w[if for while switch catch function return typeof new delete else do try].freeze

    # A controller is also attached FROM CODE:
    # `el.dataset.controller = 'short-text'` or
    # `setAttribute('data-controller', 'short-text')`. That is how an
    # initialiser works when it attaches a controller to the links it found —
    # and without these two forms `short-text` was listed as a controller
    # nothing attaches. The second false finding out of three.
    ATTACH = [
      /\.dataset\.controller\s*=\s*(?<quote>['"])(?<body>[^'"\n]*)\k<quote>/,
      /setAttribute\(\s*(?<q1>['"])data-controller\k<q1>\s*,\s*(?<quote>['"])(?<body>[^'"\n]*)\k<quote>/
    ].freeze

    Element = Struct.new(:kind, :name, :detail, :line, keyword_init: true)

    class << self
      # => [Element, …]
      # `classes` → `class_name` rather than `class`: the kind `class` already
      # means a class declaration, and a name collision would conflate two
      # different facts.
      LIST_KINDS = { 'targets' => 'target', 'classes' => 'class_name', 'outlets' => 'outlet' }.freeze

      def elements(source)
        out = []
        in_values = false
        value_indent = nil
        open_list = nil
        pending_getter = nil
        # The list of build entry points spans SEVERAL LINES, so the flag is
        # declared here: inside the loop it was reset on every line, and the
        # object form (`entryPoints = { name: 'path', … }`) never reached the
        # index at all.
        entry_block = false

        source.each_line.with_index(1) do |raw, line|
          row = raw.chomp
          next if row.match?(%r{\A\s*(//|\*|/\*)})

          # The body of `static values = { … }` is read separately: the value
          # names sit one per line, and a template can set each of them with an
          # attribute.
          if in_values
            if row.match?(/^\s*\}/) && (value_indent.nil? || row.index('}').to_i <= value_indent)
              in_values = false
            elsif (match = row.match(/^\s*(?<name>[A-Za-z_$][\w$]*)\s*:/))
              # The default is recorded next to the name: a value with a
              # default that the markup does not set is NORMAL, while without a
              # default it is always empty — and that is a finding.
              out << Element.new(kind: 'value', name: match[:name],
                                 detail: row.include?('default:') ? 'default' : nil, line: line)
            end
            next
          end
          if row.match?(STATIC_VALUES)
            # A ONE-LINE declaration (`static values = { url: String }`) is the
            # most common form, and without this check the "inside values" state
            # never closed: the parse swallowed the rest of the file together
            # with every method in it. It was found because the report declared
            # the action `payment-precheck#submit` broken while the method is
            # right there — on line eight, immediately under the values
            # declaration.
            if row.count('{') == row.count('}')
              row.scan(/([A-Za-z_$][\w$]*)\s*:/) do |(name)|
                next if name == 'default' || name == 'type'

                out << Element.new(kind: 'value', name: name,
                                   detail: row.include?('default:') ? 'default' : nil, line: line)
              end
            else
              in_values = true
              value_indent = row.index('static')
            end
            next
          end

          scan_modules(row, line, out)

          if (match = row.match(CLASS))
            out << Element.new(kind: 'class', name: match[:name].to_s, detail: match[:parent], line: line)
          end
          # A list opened and not closed on this line continues below; a getter
          # returns the list from `return`. One piece of state drives both.
          if open_list
            names(row).each { |name| out << Element.new(kind: open_list, name: name, detail: nil, line: line) }
            open_list = nil if row.include?(']')
            next
          end
          if (match = row.match(STATIC_GETTER))
            pending_getter = LIST_KINDS[match[:kind]]
            next
          end
          if pending_getter && (match = row.match(LIST_RETURN))
            names(match[:body]).each do |name|
              out << Element.new(kind: pending_getter, name: name, detail: nil, line: line)
            end
            open_list = row.include?(']') ? nil : pending_getter
            pending_getter = nil
            next
          end
          if (match = row.match(STATIC_LIST))
            kind = LIST_KINDS[match[:kind]]
            names(match[:body]).each do |name|
              out << Element.new(kind: kind, name: name, detail: nil, line: line)
            end
            open_list = kind unless row.include?(']')
          end
          row.to_enum(:scan, REGISTER).each do
            match = Regexp.last_match
            out << Element.new(kind: 'register', name: match[:identifier],
                               detail: match[:klass], line: line)
          end
          if (match = row.match(EXPORTS))
            out << Element.new(kind: 'export', name: match[:name] || export_name(match[:value]),
                               detail: nil, line: line)
          elsif (match = row.match(EXPORT_ESM))
            out << Element.new(kind: 'export', name: match[:name], detail: nil, line: line)
          end
          if (match = row.match(METHOD))
            name = match[:name]
            out << Element.new(kind: 'method', name: name, detail: nil, line: line) unless NOT_METHOD.include?(name)
          end
          ATTACH.each do |regexp|
            row.to_enum(:scan, regexp).each do
              match = Regexp.last_match
              match[:body].to_s.split(/\s+/).reject(&:empty?).each do |identifier|
                out << Element.new(kind: 'attach', name: identifier, detail: nil, line: line)
              end
            end
          end
          row.scan(PATH_JOIN) do
            parts = Regexp.last_match(:body).scan(/['"]([^'"]+)['"]/).flatten
            next if parts.empty?

            joined = parts.join('/')
            out << Element.new(kind: 'entry', name: joined, detail: 'собран из частей', line: line)
          end

          # The list of build entry points also comes as a multi-line object:
          # collect the literals until the block closes.
          entry_block = true if row.match?(ENTRY_POINTS)
          if entry_block
            # The object key is THE PACK NAME, and without it the chain
            # "template → pack → build entry → stylesheet file" does not close:
            # a template names the pack, not the path.
            row.scan(/([A-Za-z_][\w]*)\s*:\s*['"]([^'"]+\.(?:js|mjs|ts|tsx|css|scss|sass))['"]/) do
              name, target = Regexp.last_match(1), Regexp.last_match(2)
              out << Element.new(kind: 'entry', name: target, detail: name, line: line)
            end
            row.scan(/['"]([^'"]+\.(?:js|mjs|ts|tsx|css|scss|sass))['"]/).flatten.each do |entry|
              out << Element.new(kind: 'entry', name: entry, detail: nil, line: line)
            end
            entry_block = false if row.match?(/[\]}]/) && !row.match?(ENTRY_POINTS)
          end
        end
        out
      end

      # --- the template side -------------------------------------------------
      #
      # The second half of the chain. `data-controller` appears in 1,022
      # templates, and before this parse not one of them was linked to a
      # controller: "which template attaches this controller" and "does the
      # action point at an existing method" had no answer.
      #
      # By the Stimulus convention the controller name in an attribute is
      # exactly what sits between `data-` and `-target`, so no registry is
      # needed to parse a target. For a value (`data-<name>-<value>-value`),
      # though, both halves may contain hyphens and cannot be split without the
      # registry — so the middle is written whole and the view splits it by
      # joining against the registration.
      # The attribute body is everything up to THE SAME quote rather than "no
      # quotes at all": ERB sits inside it, and ERB is full of quotes of the
      # other kind (`data-…-value="<%= I18n.t('general.close') %>"`). With the
      # "no quotes whatsoever" condition such attributes were not found at all,
      # and the report declared seventeen values unset — all seventeen were
      # set.
      BODY = '(?<body>(?:(?!\\k<quote>)[^\\n])*)'
      MARKUP = {
        'use' => /data-controller\s*=\s*(?<quote>["'])#{BODY}\k<quote>/,
        'action' => /data-action\s*=\s*(?<quote>["'])#{BODY}\k<quote>/,
        'target' => /data-(?<middle>[a-z0-9-]+)-target\s*=\s*(?<quote>["'])#{BODY}\k<quote>/,
        'value' => /data-(?<middle>[a-z0-9-]+)-value\s*=\s*(?<quote>["'])#{BODY}\k<quote>/
      }.freeze
      ACTION = /(?:(?<event>[\w:.@-]+)->)?(?<identifier>[a-z][a-z0-9-]*)\#(?<method>[A-Za-z_$][\w$]*)/
      # Interpolation inside an attribute: the name is assembled at runtime, so
      # the link here is not a fact but a blind spot — recording it as a link
      # would mean inventing it.
      ERB_INSIDE = /<%|\#\{/

      # => [Element, …]; kind: use | action | target | value | dynamic
      def markup_elements(source)
        out = []
        source.each_line.with_index(1) do |row, line|
          MARKUP.each do |kind, regexp|
            row.to_enum(:scan, regexp).each do
              match = Regexp.last_match
              body = match[:body].to_s
              middle = match.names.include?('middle') ? match[:middle] : nil
              # Interpolation in the NAME is a blind spot. Interpolation in the
              # VALUE of a `…-value` attribute is ordinary
              # (`data-x-url-value="<%= path %>"`) and is not a blind spot: we
              # do not record values, we need only the name, and here it is
              # known.
              dynamic = middle.to_s.match?(ERB_INSIDE) ||
                        (kind != 'value' && body.match?(ERB_INSIDE))
              if dynamic
                out << Element.new(kind: 'dynamic', name: kind, detail: middle, line: line)
                next
              end

              case kind
              when 'use'
                body.split(/\s+/).reject(&:empty?).each do |identifier|
                  out << Element.new(kind: 'use', name: identifier, detail: nil, line: line)
                end
              when 'action'
                body.scan(ACTION) do
                  found = Regexp.last_match
                  out << Element.new(kind: 'action', name: found[:method],
                                     detail: found[:identifier], line: line)
                end
              when 'target'
                out << Element.new(kind: 'target', name: body, detail: middle, line: line)
              when 'value'
                out << Element.new(kind: 'value', name: middle, detail: body[0, 40], line: line)
              end
            end
          end
        end
        out
      end

      # --- the Ruby side -----------------------------------------------------
      #
      # The third half of the chain, and without it the report lies. A
      # controller is attached not only by template markup: a Ruby helper
      # builds the same attribute (`'data-controller' => 'infinite-scroll'`),
      # and `tag.attributes(data: { controller: 'blank-image' })` does the same.
      # While the parse looked only at HTML, `infinite-scroll` was listed as a
      # controller NOTHING attaches — while a helper of the application does.
      #
      # The short key `controller:` on its own is no good: this tree has 265
      # such places and almost all of them are routing (`controller: 'user'`).
      # So the keys are read only INSIDE a `data: { … }` hash.
      # A string key is not only `data-controller`: a helper also sets values
      # (`'data-infinite-scroll-next-url-value' => next_url.to_s`), and without
      # them the report said "the markup does not set this value" about a value
      # set by the very helper that attaches the controller.
      ATTR_STRING = /['"]data-(?<attr>controller|action|[a-z0-9-]+-(?:target|value))['"]\s*=>\s*(?<quote>['"])?(?<body>[^'",\n}]*)/
      # The hash body allows ONE level of interpolation: `data: { …,
      # dom_clear_selector_value: "##{folder_frame_id}" }` — with the "no braces
      # whatsoever" condition such hashes were not found at all, and that is the
      # most common form with the `tag.attributes` helper.
      DATA_HASH = /\bdata:\s*\{(?<body>(?:[^{}]|\#\{[^{}]*\})*)\}/
      HASH_PAIR = /(?<key>\w+):\s*(?<quote>['"])(?<body>[^'"\n]*)\k<quote>/

      # => [Element, …]; the same kinds as markup_elements.
      def ruby_elements(source)
        out = []
        source.each_line.with_index(1) do |row, line|
          row.to_enum(:scan, ATTR_STRING).each do
            match = Regexp.last_match
            attr = match[:attr]
            case attr
            when 'controller', 'action'
              collect_attribute(attr, match[:body], nil, line, out)
            when /\A(?<middle>[a-z0-9-]+)-(?<what>target|value)\z/
              found = Regexp.last_match
              collect_attribute(found[:what], match[:body], found[:middle], line, out)
            end
          end
          row.to_enum(:scan, DATA_HASH).each do
            hash = Regexp.last_match[:body]
            hash.to_enum(:scan, HASH_PAIR).each do
              pair = Regexp.last_match
              key = pair[:key]
              case key
              when 'controller' then collect_attribute('use', pair[:body], nil, line, out)
              when 'action' then collect_attribute('action', pair[:body], nil, line, out)
              when /\A(?<middle>\w+)_target\z/
                collect_attribute('target', pair[:body], Regexp.last_match[:middle].tr('_', '-'), line, out)
              when /\A(?<middle>\w+)_value\z/
                collect_attribute('value', pair[:body], Regexp.last_match[:middle].tr('_', '-'), line, out)
              end
            end
          end
        end
        out
      end

      # Where a relative module path leads. The extension is omitted in
      # `require`, and without substituting it every other edge would come out
      # as "no such file".
      SUFFIXES = ['', '.js', '.mjs', '.ts', '.tsx', '/index.js', '/index.ts'].freeze
      def resolve(from_path, target, root: Xref.root)
        return nil unless target.start_with?('.')

        base = File.join(File.dirname(from_path), target)
        SUFFIXES.each do |suffix|
          candidate = Pathname.new("#{base}#{suffix}").cleanpath.to_s
          return candidate if File.file?(File.join(root.to_s, candidate))
        end
        nil
      end

      # One parse of an attribute value for both entrances: HTML and Ruby. A
      # copy here would drift apart silently — the markup and the helper build
      # the very same attribute.
      def collect_attribute(kind, body, middle, line, out)
        kind = 'use' if kind == 'controller'
        case kind
        when 'use'
          body.to_s.split(/\s+/).reject(&:empty?).each do |identifier|
            next if identifier.match?(ERB_INSIDE)

            out << Element.new(kind: 'use', name: identifier, detail: nil, line: line)
          end
        when 'action'
          body.to_s.scan(ACTION) do
            found = Regexp.last_match
            out << Element.new(kind: 'action', name: found[:method], detail: found[:identifier], line: line)
          end
        when 'target'
          out << Element.new(kind: 'target', name: body.to_s, detail: middle, line: line)
        when 'value'
          out << Element.new(kind: 'value', name: middle, detail: body.to_s[0, 40], line: line)
        end
      end

      private

      # A line that is ENTIRELY a string literal is usually source assembled at
      # runtime (that is how a probe bundle for checking a controller is built
      # here). A `require` inside it is text rather than an import, and it is
      # relative to a different file: the single finding "an import leading
      # nowhere" turned out to be exactly that case.
      QUOTED_LINE = /\A\s*(['"]).*\1\s*,?\s*\z/

      def scan_modules(row, line, out)
        return if row.match?(QUOTED_LINE)

          if (match = row.match(BINDINGS))
            match[:body].scan(/[A-Za-z_$][\w$]*/).each do |binding|
              next if %w[type as default].include?(binding)

              out << Element.new(kind: 'binding', name: binding, detail: match[:path], line: line)
            end
          end
          # THE HEAD OF A DECLARATION is not a call. `function build(el)`
          # matches the call pattern itself, and without cutting it off every
          # declared function would have a "call" from its own line — so there
          # would NEVER be any dead ones. The rest of the line is still scanned:
          # in `const x = () => build(y)` the call is real.
          call_row = row
          [FUNCTION, ARROW, GLOBAL_FUNCTION].each do |regexp|
            next unless (match = row.match(regexp))

            out << Element.new(kind: 'function', name: match[:name], detail: nil, line: line)
            call_row = call_row.sub(/\A.*?#{Regexp.escape(match[:name])}/, '')
          end
          # STRINGS AND REGEXPS are not code. `/^(?:letdiv)_\d+_(\d+)$/` yields
          # "a call to `_`", and the report would have declared that the tree
          # calls lodash as a global (verified: it does not, that is a regexp in
          # a controller). They are masked before calls are searched for.
          masked_row = call_row.gsub(/'(?:\\.|[^'\\])*'/, "''")
                               .gsub(/"(?:\\.|[^"\\])*"/, '""')
                               .gsub(%r{(?<=[=(,:\[!&|?+\s])/(?:\\.|[^/\\\n])+/[gimsuy]*}, '//')
          # A template literal is masked, but the interpolations inside it are
          # KEPT: in `${build(x)}` the call is real while the text around it is
          # not. The last false "call to `_`" lived exactly there:
          # `` `^(?:letdiv)_${partner}_(\d+)$` ``.
          masked_row = masked_row.gsub(/`(?:\\.|[^`\\])*`/) do |span|
            span.scan(/\$\{[^}]*\}/).join(' ')
          end
          masked_row.scan(CALL) do
            name = Regexp.last_match(:name)
            out << Element.new(kind: 'call', name: name, detail: nil, line: line) unless NOT_A_CALL.include?(name)
          end
        [REQUIRE, DYNAMIC_IMPORT, IMPORT_FROM, IMPORT_BARE].each do |regexp|
          row.to_enum(:scan, regexp).each do
            match = Regexp.last_match
            out << Element.new(kind: 'import', name: match[:path], detail: nil, line: line)
          end
        end
      end

      def names(body)
        body.to_s.scan(/['"]([^'"]+)['"]/).flatten
      end

      # `module.exports = Name` against `module.exports = { A, B }` and
      # `module.exports = class extends …`.
      def export_name(value)
        text = value.to_s.strip
        return 'class' if text.start_with?('class')
        return nil if text.start_with?('{')

        text[/\A[\w$.]+/]
      end
    end
  end
end
