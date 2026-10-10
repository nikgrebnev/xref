# frozen_string_literal: true

require 'prism'
require 'open3'

module Xref
  # Call sites — but not a call graph.
  #
  # The index has no call graph and will not have one: over 600 thousand lines
  # with metaprogramming the receiver cannot be resolved, and false confidence
  # costs more than it gives. The job here is different and far narrower: the
  # root of a hole in a query is a method parameter (`make_param(sql, table)`
  # substitutes `sql` into `in (…)`), and it has to be visible WHAT the callers
  # pass into that parameter. There are dozens of such method names, not
  # thousands, and the question about each is finite.
  #
  # So the parse happens on demand and only for the names given: first
  # `git grep -w` narrows the tree down to a few files, then those are parsed
  # with Prism. Nothing is stored: the answer lives exactly as long as the
  # command.
  class CallSites
    Call = Struct.new(:path, :line, :scope, :method, :receiver, :args, :via, keyword_init: true)

    # Templates are parsed on equal terms with Ruby. Prism will not build a tree
    # out of `.erb`, but real Ruby can be assembled from the tags — exactly the
    # way ERB itself does it: the text between tags is dropped, the newlines are
    # kept so that the line numbers match the file. `<% if %>` and `<% end %>`
    # from different tags then come together into one expression, and a call
    # inside a branch is visible.
    #
    # Without this "who calls it" lied in the most frequent direction: helpers
    # are called from views, and they came out with zero calls while three
    # thousand templates sat right next to them.
    EXTENSIONS = %w[.rb .rake .ru .erb .builder .jbuilder].freeze

    # `send(:make_param, …)` is the same call, only with the name in an argument.
    SEND_METHODS = %w[send public_send __send__].freeze

    Mention = Struct.new(:path, :line, :text, :kind, keyword_init: true)

    # stats — an optional hash that receives numbers about the parse itself: how
    # many files were read and how many `send` calls with a dynamically
    # assembled name were met. The latter is a blind spot: any such call may
    # call anything, and staying silent about them is not allowed.
    # paths — a ready list of files instead of a grep search. Needed when there
    # are thousands of names (the sweep for dead private methods): a grep with
    # six thousand patterns returns almost the whole tree anyway, and reading it
    # once is cheaper.
    def self.find(names, root: Xref.root, stats: nil, paths: nil)
      names = Array(names).map(&:to_s).reject(&:empty?).uniq
      return [] if names.empty?

      finder = new(names, root, paths)
      calls = finder.run
      stats&.merge!(files: finder.files_scanned, dynamic_sends: finder.dynamic_sends)
      calls
    end

    # Mentions of a name OUTSIDE calls: specs, inventories, documents,
    # templates, comments. They are needed where no calls were found at all:
    # "the method is dead" without this list reads as "I will delete it", while
    # what keeps it alive is usually a spec or an inventory — and then it has to
    # be removed as a pair. That is exactly what happened here: nothing calls
    # `make_param`, but a spec about literals in pg_stat_statements has an
    # exception registered for its line.
    IGNORED = %r{\A(vendor/|node_modules/|public/|tmp/|log/)}
    KINDS = {
      %r{\Aspec/} => 'спека',
      %r{\Adoc/|\.md\z} => 'документ',
      %r{\Aapp/views/|\.(erb|haml|slim|builder|jbuilder)\z} => 'шаблон',
      %r{\.(yml|yaml|json)\z} => 'настройка',
      %r{\Ascript/|\Alib/tasks/} => 'скрипт'
    }.freeze

    # The same thing, but for hundreds of names at once. `git grep` is no good
    # here: with two hundred patterns it does not finish within ten minutes on
    # this tree (verified 2026-09-06), whereas one combined expression walks all
    # the files in seconds. Needed by the dead-method sweep: "dead" without the
    # list of what holds it leads to "I will delete it", and what holds it is
    # usually a spec or an inventory.
    def self.mentions_many(names, root: Xref.root, limit: MENTION_LINES, stats: nil)
      names = Array(names).map(&:to_s).reject(&:empty?).uniq
      result = Hash.new { |store, key| store[key] = [] }
      return result if names.empty?

      # The word of a name is found IN THE TREE by a text search (`rg`), but the
      # decision is made by the expression below. Measured 2026-10-09: a Ruby
      # pass over 196 MB cost 33 s and was the most expensive half of
      # `bin/xref dead`; `rg` returns the same lines in 1.3 s. The search here
      # is a PREFILTER rather than the answer: it searches by the stem of the
      # name (`part_exists?` → `part_exists`), so it deliberately finds more
      # than is needed.
      union = mention_regexp(names)
      wanted = names.to_set
      candidate_mention_lines(names, root: root, limit: limit, stats: stats) do |path, line, row|
        next unless row.match?(union)

        kind = KINDS.find { |regexp, _| path.match?(regexp) }&.last
        # Non-Latin letters in a method name are not a fantasy: this tree holds
        # 45 of them. With the previous `[A-Za-z_]` their mentions were
        # invisible, so a method with such a name read as "mentioned nowhere" —
        # and went into the removal candidates.
        row.scan(/[\p{L}_][\p{L}\p{N}_]*[?!]?/) do |word|
          next unless wanted.include?(word)
          next if row.match?(/\bdef\s+(?:self\.)?#{Regexp.escape(word)}\b/)

          result[word] << Mention.new(path: path, line: line,
                                      text: row.strip[0, 120],
                                      kind: kind || (row.strip.start_with?('#') ? 'комментарий' : 'код'))
        end
      end
      result
    end

    # How many candidate lines are taken from the search. Hitting this limit
    # means a TRUNCATED answer, and truncation here lies in the dangerous
    # direction: "no mentions" reads as "safe to remove". So on hitting it the
    # code falls back to a full pass.
    #
    # Four hundred thousand is comfortably above what was measured: 271 dead
    # names yield 61,367 candidate lines, because some of the names are short
    # and frequent (`act` — 48 thousand lines). The limit is here not for speed
    # but against a name that matches half the tree.
    MENTION_LINES = 400_000

    def self.mention_regexp(names)
      /(?<![\p{L}\p{N}_])(?:#{names.map { |name| Regexp.escape(name) }.join('|')})(?![\p{L}\p{N}_])/
    end

    # Candidate lines: first via a text search, and if that is unavailable or
    # its answer was truncated — via a full pass over the tree. The second path
    # is more honest but thirty times more expensive, and the report must know
    # which one was taken (`stats[:scan]`).
    def self.candidate_mention_lines(names, root:, limit:, stats: nil, &block)
      stems = names.map { |name| name.sub(/[?!=]\z/, '') }.uniq.reject(&:empty?)
      hits = begin
        Xref::TextSearch.lines(stems.map { |stem| Regexp.escape(stem) }.join('|'),
                               root: root, word: true, limit: limit)
      rescue StandardError
        nil
      end

      if hits && hits.size < limit
        stats&.merge!(scan: 'поиск по тексту', lines: hits.size)
        hits.each { |hit| block.call(hit.path, hit.line, hit.text) unless hit.path.match?(IGNORED) }
        return
      end

      stats&.merge!(scan: hits ? 'полный проход (ответ поиска обрезан)' : 'полный проход (поиска нет)')
      union = mention_regexp(names)
      each_tracked_file(root) do |path, text|
        next unless text.match?(union)

        text.each_line.with_index(1) { |row, line| block.call(path, line, row) }
      end
    end

    # Which route helpers (`login_path`, `account_url`) are mentioned in the
    # tree at all. One expression over all files instead of a thousand patterns:
    # the route names are not known in advance, and collecting them all in one
    # pass is cheaper than searching for each.
    def self.route_helpers(root: Xref.root)
      pattern = /\b([a-z][a-z0-9_]*)_(?:path|url)\b/
      used = Set.new
      hits = Xref::TextSearch.matches(pattern.source, root: root, globs: SEARCH_SKIP)
      if hits
        hits.each { |found| used << Regexp.last_match(1) if found.match(pattern) }
      else
        each_tracked_file(root) do |_path, text|
          text.scan(pattern) { |(name)| used << name }
        end
      end
      used
    end

    # URLs written as strings: `link_to '/gallery/approve'`,
    # `action="/user/save"`, `href="/settings/delete_profile"`. In this tree
    # that is more common than going through helpers, and without such a search
    # "nothing mentions this route" would be true for half the production pages.
    #
    # One pattern for both paths. The start-of-line alternative in it is
    # DELIBERATE: a text search looks line by line, and a URL at the very start
    # of a line has no preceding character — without `^` the search lost 902
    # URLs out of ten thousand (`.gitignore`, path listings), which made
    # "nothing mentions this route" truer for each of them.
    LITERAL_PATH = %r{(?:^|["'(=\s])(/[a-z][a-z0-9_/-]{2,})}i
    # Directories absent from the answer of the full pass (`IGNORED`): a text
    # search does enter them, and without the exclusion it brought back URLs
    # from the documentation of gems.
    SEARCH_SKIP = ['!vendor/*', '!node_modules/*', '!public/*', '!tmp/*', '!log/*'].freeze

    # HOW THE SEARCH ANSWER DIFFERS FROM THE FULL-PASS ANSWER — compared as
    # sets rather than taken on trust (2026-10-09):
    #
    #   * the search finds MORE: the full pass skips files larger than 4 MB, and
    #     those hold machine-generated inventories — 412 URLs and 13 route
    #     helpers it never saw at all. That is the side where an error is
    #     dangerous: "nothing mentions it" reads as "safe to remove";
    #   * the search finds 863 URLs FEWER, and all 863 come from BINARY files
    #     (`rg` does not read them): `/c2pa/urn` out of a png, `/rdkqjk9d`,
    #     which not even grep finds. Checked directly: NOT ONE of them matches
    #     a route of the application, so no route looks dead because of it.

    def self.literal_paths(root: Xref.root)
      seen = Set.new
      # `(?i)` is written EXPLICITLY: `source` does not carry the
      # case-insensitivity flag, and without it the search found 6,064 URLs
      # instead of ten thousand.
      hits = Xref::TextSearch.matches("(?i)#{LITERAL_PATH.source}", root: root, globs: SEARCH_SKIP)
      if hits
        hits.each { |found| seen << Regexp.last_match(1).downcase.chomp('/') if found.match(LITERAL_PATH) }
      else
        each_tracked_file(root) do |_path, text|
          text.scan(LITERAL_PATH) { |(found)| seen << found.downcase.chomp('/') }
        end
      end
      seen
    end

    def self.each_tracked_file(root)
      out, = Open3.capture2('git', '-C', root.to_s, 'ls-files', '-z')
      Xref.utf8(out).split("\0").each do |path|
        next if path.match?(IGNORED)

        full = File.join(root.to_s, path)
        next unless File.file?(full) && File.size(full) < 4_000_000

        text = File.read(full, encoding: 'UTF-8').scrub('')
        yield path, text
      rescue StandardError
        next
      end
    end

    def self.mentions(name, root: Xref.root, skip: [])
      out, _err, status = Open3.capture3('git', '-C', root.to_s, 'grep', '-n', '-w', '-F', '-e', name.to_s)
      return [] unless status.exitstatus.to_i < 2

      known = skip.map { |call| [call.path, call.line] }.to_set
      # The output of `git grep` is LINES OF FILES, that is, non-Latin text all
      # the way through. With no locale it arrives as US-ASCII, and `split` dies
      # on the first such letter.
      Xref.utf8(out).split("\n").filter_map do |row|
        path, line, text = row.split(':', 3)
        next if path.nil? || path.match?(IGNORED) || text.nil?
        next if known.include?([path, line.to_i])
        # The declaration itself is not a mention.
        next if text.match?(/\bdef\s+(?:self\.)?#{Regexp.escape(name.to_s)}\b/)

        kind = KINDS.find { |pattern, _| path.match?(pattern) }&.last
        kind ||= text.strip.start_with?('#') ? 'комментарий' : 'код'
        Mention.new(path: path, line: line.to_i, text: text.strip[0, 120], kind: kind)
      end
    end

    attr_reader :files_scanned, :dynamic_sends

    def initialize(names, root, paths = nil)
      @names = names.to_set
      @root = root
      @paths = paths
      @files_scanned = 0
      @dynamic_sends = 0
      @line_offset = 0
    end

    def run
      paths = @paths || candidate_paths
      @files_scanned = paths.size
      paths.flat_map { |path| scan(path) }
    end

    private

    # `git grep -l -w` by whole words: there is no point parsing seven thousand
    # files for a dozen names, and a substring match would bring in
    # `make_param_list` as well.
    def candidate_paths
      pattern = @names.flat_map { |name| ['-e', name] }
      out, _err, status = Open3.capture3('git', '-C', @root.to_s, 'grep', '-l', '-w', '-F',
                                         *pattern, '--', *EXTENSIONS.map { |e| "*#{e}" })
      # grep returns 1 when it found nothing — that is not an error.
      return [] unless status.exitstatus.to_i < 2

      Xref.utf8(out).split("\n").reject { |path| path.start_with?('vendor/', 'node_modules/') }
    end

    def scan(path)
      full = @root.join(path)
      return [] unless File.file?(full)

      source = File.read(full, encoding: 'UTF-8').scrub('')
      @path = path
      @found = []
      @stack = []
      @consumed = Set.new
      @method = nil
      @template = template?(path)

      if @template
        parse_template(source)
      else
        result = Prism.parse(source)
        walk(result.value) if result.success?
      end
      @found
    rescue StandardError
      []
    end

    def template?(path)
      %w[.erb .builder .jbuilder].include?(File.extname(path))
    end

    # First as a whole: a branch spread across tags is glued back together and
    # yields a real tree. If that does not work out (and it happens: a tag
    # inside an attribute, a fragment split across two views), each tag is
    # parsed separately — some of the calls are visible anyway.
    def parse_template(source)
      whole = File.extname(@path) == '.erb' ? erb_ruby(source) : source
      result = Prism.parse(whole)
      return walk(result.value) if result.success?

      each_erb_tag(source) do |code, line|
        piece = Prism.parse(code)
        next unless piece.success?

        @line_offset = line - 1
        walk(piece.value)
        @line_offset = 0
      end
    end

    # Ruby out of the tags, with the line numbers preserved. There is one
    # implementation for the whole index (`Xref::Erb`): `CodeScanner` parses
    # templates with the same trick, and two copies would drift apart silently.
    def erb_ruby(source)
      Erb.ruby(source)
    end

    def each_erb_tag(source, &block)
      Erb.each_tag(source, &block)
    end

    def walk(node)
      return if node.nil?

      case node
      when Prism::ClassNode, Prism::ModuleNode
        @stack.push(constant_name(node.constant_path))
        node.compact_child_nodes.each { |child| walk(child) }
        @stack.pop
        return
      when Prism::DefNode
        previous = @method
        @method = "#{node.receiver ? '.' : '#'}#{node.name}"
        node.compact_child_nodes.each { |child| walk(child) }
        @method = previous
        return
      when Prism::CallNode
        if @names.include?(node.name.to_s)
          record(node)
        elsif SEND_METHODS.include?(node.name.to_s)
          record_send(node)
        end
      when Prism::SymbolNode
        # `before_action :check_gate`, `helper_method :x`, `alias_method`,
        # `rescue_from … with: :handler`, `method(:x)` — the method is named
        # without being called. For the question "is it dead" that is as good a
        # hook as a call: without it half the private methods of the
        # controllers would read as dead, while a filter calls them.
        #
        # A symbol out of `send(:x)` does not reach here: it was already
        # recorded as a call, and a second row on the same line would inflate
        # the call count twofold.
        if @names.include?(node.unescaped.to_s) && !@consumed.include?(node.object_id)
          record(node, method: node.unescaped.to_s, arguments: [],
                       via: @template ? 'шаблон, символ' : 'символ')
        end
      end

      node.compact_child_nodes.each { |child| walk(child) }
    end

    # A declaration is not a call. `def make_param` never reaches here (DefNode
    # is caught earlier), but `make_param` with no parentheses and no arguments
    # is a read of a local variable just as often as it is a call, and telling
    # the two apart without a runtime is impossible. Such places are marked with
    # an empty argument list.
    def record(node, method: nil, arguments: nil, via: nil)
      arguments ||= node.arguments&.arguments || []
      @found << Call.new(
        path: @path, line: node.location.start_line + @line_offset.to_i, scope: scope_name,
        method: method || node.name.to_s,
        receiver: (node.receiver&.slice.to_s.gsub(/\s+/, ' ')[0, 60] if node.respond_to?(:receiver)),
        args: arguments.map { |a| a.slice.to_s.gsub(/\s+/, ' ').strip[0, 120] },
        via: via || (@template ? 'шаблон' : nil)
      )
    end

    # `obj.send(:make_param, sql, table)` — the name is in the first argument,
    # the remaining arguments are the same ones. A first argument assembled on
    # the fly (`send(action)`) cannot be named: such a place stays a blind spot,
    # and the report counts those separately.
    def record_send(node)
      arguments = node.arguments&.arguments || []
      first = arguments.first
      name =
        case first
        when Prism::SymbolNode, Prism::StringNode then first.unescaped.to_s
        end
      @consumed << first.object_id if first
      if name.nil?
        @dynamic_sends += 1
        return
      end
      return unless @names.include?(name)

      record(node, method: name, arguments: arguments.drop(1),
                   via: @template ? 'шаблон, send' : 'send')
    end

    def scope_name
      klass = @stack.reject(&:empty?).join('::')
      return klass if @method.nil?

      klass.empty? ? @method.to_s : "#{klass}#{@method}"
    end

    def constant_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then (node.full_name rescue node.name.to_s).to_s
      else ''
      end
    end
  end
end
