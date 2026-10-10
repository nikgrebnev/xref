# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'tmpdir'

# Parsing JavaScript and Stimulus (the specification).
#
# Every example below closes a mistake that ALREADY produced a false finding
# once when checked against a live tree. All four went in one direction: the
# report declared broken what works. That is the worst kind of error for a tool
# — after such an answer people stop trusting the rest of them.
RSpec.describe Xref::Js do
  def of(source, kind)
    described_class.elements(source).select { |e| e.kind == kind }
  end

  # TYPESCRIPT. A project entirely on TS got SIX false findings from the index:
  # three "the controller is not registered" with the registration sitting in
  # `application.ts` and three "NO SUCH METHOD" with the methods in place —
  # because the layer was not scanned at all. The examples below close each
  # cause separately.
  describe 'TypeScript' do
    it 'finds a method with a return type and an access modifier' do
      source = <<~TS
        export default class ThemeController extends Controller {
          static targets = ["toggle"]

          private choose(event: Event): void {
            event.preventDefault()
          }

          public async save<T>(value: T): Promise<void> {
            await this.store(value)
          }
        }
      TS

      expect(of(source, 'method').map(&:name)).to include('choose', 'save')
    end

    it 'sees the registration of a controller in application.ts' do
      source = <<~TS
        import ThemeController from "./controllers/theme_controller"
        application.register("theme", ThemeController)
      TS

      expect(of(source, 'register').map(&:name)).to eq(['theme'])
    end

    # A build root is named in the bundler config rather than in package.json: a
    # file nobody imports because it is RUN is not a removal candidate.
    it 'takes the build roots out of entryPoints in the bundler config' do
      source = <<~JS
        export default {
          entryPoints: ["app/javascript/application.ts", "app/javascript/service_worker.ts"],
          bundle: true
        }
      JS

      expect(of(source, 'entry').map(&:name))
        .to eq(['app/javascript/application.ts', 'app/javascript/service_worker.ts'])
    end

    it 'resolves an import into a .ts file and into a directory with index.ts' do
      Dir.mktmpdir('xref-ts') do |dir|
        root = Pathname.new(dir)
        FileUtils.mkdir_p(root.join('app/javascript/controllers/panel'))
        root.join('app/javascript/controllers/theme_controller.ts').write("export default 1\n")
        root.join('app/javascript/controllers/panel/index.ts').write("export default 2\n")

        expect(described_class.resolve('app/javascript/application.ts', './controllers/theme_controller', root: root))
          .to eq('app/javascript/controllers/theme_controller.ts')
        expect(described_class.resolve('app/javascript/application.ts', './controllers/panel', root: root))
          .to eq('app/javascript/controllers/panel/index.ts')
      end
    end
  end

  # TOP-LEVEL FUNCTIONS AND CALLS. Class methods were known to the index, these
  # were not: the tree holds about five hundred of them, and half the code could
  # not answer "who calls this".
  describe 'functions and calls' do
    it 'takes a declaration in three forms' do
      source = <<~JS
        export function initPanel(el) { return 1 }
        const render = (x) => x
        window.legacyBoot = function () { return 2 }
      JS

      expect(of(source, 'function').map(&:name)).to contain_exactly('initPanel', 'render', 'legacyBoot')
    end

    # THE HEAD OF A DECLARATION is not a call. Without cutting it off every
    # function would have a "call" from its own line, and there would NEVER be
    # any dead ones.
    it 'does not count a declaration as a call while counting a call on the same line' do
      source = "function build(el) { return el }\nconst render = (x) => build(x)\n"

      expect(of(source, 'call').map(&:name)).to eq(['build'])
    end

    # A dot before the name is a method access (we do not resolve receivers),
    # while THREE dots are a spread, and that is an ordinary call. Without the
    # second branch the very last verified "the function is dead" finding turned
    # out false.
    it 'counts a call through a spread and does not count a method access' do
      source = "const o = { ...errorMessageOption() }\nconst p = obj.method()\nplain()\n"

      expect(of(source, 'call').map(&:name)).to contain_exactly('errorMessageOption', 'plain')
    end

    # STRINGS AND REGEXPS are not code. The regexp `/…_(\d+)$/` yielded "a call
    # to `_`", and the report would have declared that the tree calls lodash as a
    # global; the check showed a regexp in a controller.
    it 'does not count a call inside a string or a regexp as a call' do
      source = <<~JS
        const own = /^(?:letdiv|ltr_div)_\\d+_(\\d+)$/.exec(id)
        const msg = "call fake(" + x
        real(y)
      JS

      expect(of(source, 'call').map(&:name)).to eq(['real'])
    end

    # A template literal is masked while the interpolations inside it are kept:
    # in `${build(x)}` the call is real while the regexp text around it is not.
    it 'sees an interpolation inside a template literal but not the text' do
      source = "const r = new RegExp(`^(?:letdiv)_${partner}_(\\d+)$`)\nconst t = `x ${build(y)} z`\n"

      expect(of(source, 'call').map(&:name)).to contain_exactly('RegExp', 'build')
    end

    it 'does not count language keywords as calls' do
      expect(of("if (x) { return typeof y }\n", 'call').map(&:name)).to be_empty
    end

    # Import bindings — through them we count WHETHER a library is still called.
    # There is no point going inside a library: "unused" is the majority in
    # there by construction.
    it 'takes the import bindings together with the package' do
      source = "import $ from \"jquery\"\nimport { Modal, Tooltip } from \"bootstrap\"\n"

      expect(of(source, 'binding').map { |e| [e.name, e.detail] })
        .to contain_exactly(['$', 'jquery'], ['Modal', 'bootstrap'], ['Tooltip', 'bootstrap'])
    end
  end

  describe 'a class and its contents' do
    # Mistake 1. A ONE-LINE `static values = { url: String }` did not close the
    # "inside values" state, and the parse swallowed the rest of the file
    # together with every method. The report said "the action
    # payment-precheck#submit points at a method that does not exist", while the
    # method is right there on line eight.
    it 'does not let a one-line values declaration swallow the rest of the file' do
      source = <<~JS
        class PaymentPrecheckController extends Controller {
          static values = { url: String }

          async submit(event) {
            event.preventDefault()
          }
        }
      JS

      expect(of(source, 'value').map(&:name)).to eq(['url'])
      expect(of(source, 'method').map(&:name)).to eq(['submit'])
    end

    it 'reads a multi-line values declaration by names' do
      source = <<~JS
        class A extends Controller {
          static values = {
            cookieName: { type: String, default: 'show_popup' },
            message: String
          }

          connect() {}
        }
      JS

      expect(of(source, 'value').map { |e| [e.name, e.detail] })
        .to eq([['cookieName', 'default'], ['message', nil]])
      expect(of(source, 'method').map(&:name)).to eq(['connect'])
    end

    # Mistake 2. Seven controllers out of twenty-one declare targets with a
    # GETTER, and without that form their targets were listed as undeclared.
    it 'takes targets from all three forms of declaration' do
      inline = "class A extends Controller {\n  static targets = ['items', 'pagination']\n}\n"
      getter = "class B extends Controller {\n  static get targets() {\n    return ['track', 'fill']\n  }\n}\n"
      wrapped = "class C extends Controller {\n  static targets = ['one',\n    'two']\n}\n"

      expect(of(inline, 'target').map(&:name)).to eq(%w[items pagination])
      expect(of(getter, 'target').map(&:name)).to eq(%w[track fill])
      expect(of(wrapped, 'target').map(&:name)).to eq(%w[one two])
    end

    it 'does not count keywords as methods' do
      source = "class A extends Controller {\n  connect() {\n    if (x) { y() }\n    for (;;) {}\n  }\n}\n"

      expect(of(source, 'method').map(&:name)).to eq(['connect'])
    end
  end

  describe 'modules' do
    it 'takes both require and import' do
      source = <<~JS
        const { Controller } = require('@hotwired/stimulus')
        const lib = require('../lib/manager_scope')
        import helper from './helper'
      JS

      expect(of(source, 'import').map(&:name))
        .to contain_exactly('@hotwired/stimulus', '../lib/manager_scope', './helper')
    end

    # Mistake 3. The single "an import leads nowhere" finding turned out to be a
    # `require` inside A STRING: that is how the source of a probe bundle is
    # assembled, and the path in it is relative to a different file.
    it 'does not count a require inside a string literal as an import' do
      source = <<~JS
        const entry = [
          "const C = require('./app/javascript/controllers/manager_menu_controller')",
          'const application = Application.start()'
        ]
      JS

      expect(of(source, 'import')).to be_empty
    end

    it 'has the registration link a name from the markup to a class' do
      source = "application.register('header-counters', HeaderCountersController)\n"
      found = of(source, 'register').first

      expect([found.name, found.detail]).to eq(['header-counters', 'HeaderCountersController'])
    end
  end

  describe 'the markup side' do
    def markup(source, kind)
      described_class.markup_elements(source).select { |e| e.kind == kind }
    end

    it 'takes a controller attachment, including several in one attribute' do
      expect(markup('<div data-controller="a b">', 'use').map(&:name)).to eq(%w[a b])
    end

    it 'splits an action into a controller and a method' do
      found = markup('<form data-action="submit->fragment-request#load">', 'action').first

      expect([found.detail, found.name]).to eq(['fragment-request', 'load'])
    end

    # Mistake 4. The attribute body was described as "no quotes whatsoever",
    # while ERB sits inside it with quotes of the other kind. Such attributes
    # were not found, and the report declared seventeen values unset — all of
    # them were set.
    it 'takes an attribute with quotes of the other kind inside it' do
      source = %(<div data-header-counters-close-text-value="<%= I18n.t('general.close') %>">)

      expect(markup(source, 'value').map(&:name)).to eq(['header-counters-close-text'])
    end

    it 'has the middle be the controller name and the value be the target name' do
      found = markup('<div data-infinite-scroll-target="items">', 'target').first

      expect([found.detail, found.name]).to eq(['infinite-scroll', 'items'])
    end

    # An interpolation in the NAME is a blind spot, while one in the value of a
    # `…-value` attribute is ordinary: we do not record values, we need the name.
    it 'counts an interpolation in the name as a blind spot and one in the value as not' do
      expect(markup('<div data-controller="<%= name %>">', 'dynamic')).not_to be_empty
      expect(markup('<div data-x-url-value="<%= path %>">', 'dynamic')).to be_empty
      expect(markup('<div data-x-url-value="<%= path %>">', 'value').map(&:name)).to eq(['x-url'])
    end
  end

  # The third and fourth halves of the chain. A controller is attached not only
  # by template markup: a Ruby helper builds it and code attaches it at runtime.
  # Without those two parses the report called three controllers dead, of which
  # one is dead.
  describe 'the Ruby side' do
    def ruby(source, kind)
      described_class.ruby_elements(source).select { |e| e.kind == kind }
    end

    it 'counts an attribute assembled as a string in a helper as an attachment' do
      source = <<~RUBY
        attrs = {
          'data-controller' => 'infinite-scroll',
          'data-infinite-scroll-next-url-value' => next_url.to_s
        }
      RUBY

      expect(ruby(source, 'use').map(&:name)).to eq(['infinite-scroll'])
      expect(ruby(source, 'value').map(&:name)).to eq(['infinite-scroll-next-url'])
    end

    it 'parses a data: hash, including one with an interpolation inside' do
      # Single quotes, so that `\#{…}` stays text: that is exactly how this
      # interpolation looks in a template.
      source = %q(tag.attributes(data: { controller: 'dom-clear', action: 'click->dom-clear#clear', dom_clear_selector_value: "##{folder_frame_id}" }))

      expect(ruby(source, 'use').map(&:name)).to eq(['dom-clear'])
      expect(ruby(source, 'action').map { |e| [e.detail, e.name] }).to eq([['dom-clear', 'clear']])
      expect(ruby(source, 'value').map(&:name)).to eq(['dom-clear-selector'])
    end

    # The short key `controller:` outside a `data:` hash is routing, and this
    # tree holds 265 such places.
    it 'does not count controller: outside a data hash as an attachment' do
      expect(ruby("redirect_to controller: 'user', action: 'show'", 'use')).to be_empty
    end
  end

  describe 'attachment from code' do
    it 'counts dataset.controller and setAttribute as an attachment' do
      source = <<~JS
        link.dataset.controller = 'short-text'
        el.setAttribute('data-controller', 'lm-modal-link')
      JS

      expect(of(source, 'attach').map(&:name)).to contain_exactly('short-text', 'lm-modal-link')
    end
  end

  describe 'resolving a module path' do
    # The example writes its own files and passes its own root: resolution asks
    # the filesystem, and leaning on the tree the spec happens to run in makes it
    # green in one tree and red in another.
    it 'substitutes the extension: a require omits it' do
      Dir.mktmpdir('xref-js') do |dir|
        root = Pathname.new(dir)
        FileUtils.mkdir_p(root.join('app/javascript/controllers'))
        root.join('app/javascript/controllers/application.js').write("export default 1\n")

        expect(described_class.resolve('app/javascript/controllers/a_controller.js',
                                       './application', root: root))
          .to eq('app/javascript/controllers/application.js')
      end
    end

    it 'does not treat an external package as a path in the tree' do
      expect(described_class.resolve('app/javascript/a.js', '@hotwired/stimulus')).to be_nil
    end
  end
end
