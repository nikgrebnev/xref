# -*- encoding : utf-8 -*-
require 'spec_helper'
require 'tmpdir'

# Parsing stylesheets (the specification).
#
# The layer is young, and it carries the same danger as the rest: the answer
# "the class is not needed" reads as a verdict. So the examples below cover
# exactly the cases where a naive parse lies — and lies in the direction of
# "safe to throw out".
RSpec.describe Xref::Css do
  def of(source, kind)
    described_class.elements(source).select { |e| e.kind == kind }.map(&:name)
  end

  it 'takes the classes and the ids of a selector' do
    source = ".btn, .btn-ghost { color: red }\n#main .inner { padding: 0 }\n"

    expect(of(source, 'class')).to contain_exactly('btn', 'btn-ghost', 'inner')
    expect(of(source, 'id')).to eq(['main'])
  end

  it 'does not treat a name from a comment as a class' do
    expect(of("/* .nope { } */\n.yes { color: red }\n", 'class')).to eq(['yes'])
  end

  # `&-big` inside `.btn` declares `.btn-big`, and that name does NOT exist in
  # the file in full. Without assembling it the report calls `btn-big`
  # undeclared where a rule does exist — and that is the straight road to "the
  # class is not needed, throw it out".
  it 'assembles a name out of an SCSS ampersand' do
    source = ".btn {\n  &-big { font-size: 2em }\n  &.active { color: blue }\n}\n"

    expect(of(source, 'class')).to include('btn', 'btn-big', 'active')
  end

  it 'does not treat a media condition as a selector while parsing its body' do
    source = "@media (max-width: 600px) { .mobile-only { display: block } }\n"

    expect(of(source, 'class')).to eq(['mobile-only'])
  end

  # `@apply` is a USE of the class by the stylesheet itself: the markup may not
  # need it while its rule is alive.
  it 'sees @apply as a use' do
    expect(of(".card { @apply text-sm font-bold; }\n", 'apply')).to eq(%w[text-sm font-bold])
  end

  it 'takes the targets of @import and @use' do
    expect(of("@import 'base/reset';\n@use \"palette\" as p;\n", 'import'))
      .to eq(['base/reset', 'palette'])
  end

  describe '.resolve' do
    around do |example|
      Dir.mktmpdir('xref-css') do |dir|
        @root = Pathname.new(dir)
        example.run
      end
    end

    def write(path, body = "a { color: red }\n")
      full = @root.join(path)
      FileUtils.mkdir_p(full.dirname)
      full.write(body)
    end

    it 'finds a file by a name with no extension' do
      write('app/javascript/css/palette.scss')

      expect(described_class.resolve('app/javascript/app.scss', 'css/palette', root: @root))
        .to eq('app/javascript/css/palette.scss')
    end

    # A partial SCSS file is named with an underscore which the reference does
    # not write. Without this rule every `@import 'base/reset'` would lead
    # "nowhere", and the file would be listed as needed by nobody.
    it 'finds a partial file with an underscore' do
      write('app/javascript/base/_reset.scss')

      expect(described_class.resolve('app/javascript/app.scss', 'base/reset', root: @root))
        .to eq('app/javascript/base/_reset.scss')
    end

    # `@import 'tailwindcss'` is a PACKAGE rather than a path in the tree. While
    # they went into "leads nowhere", the report called eleven live build lines
    # broken; all eleven were packages.
    it 'tells a reference to a package from a broken one' do
      FileUtils.mkdir_p(@root.join('node_modules/tailwindcss'))
      FileUtils.mkdir_p(@root.join('node_modules/@uppy/core'))

      expect(described_class.package?('tailwindcss', root: @root)).to be(true)
      expect(described_class.package?('@uppy/core/css/style.css', root: @root)).to be(true)
      expect(described_class.package?('./local.css', root: @root)).to be(false)
      expect(described_class.package?('base/reset', root: @root)).to be(false)
    end

    it 'does not treat an external URL as a target' do
      expect(described_class.resolve('a.scss', 'https://fonts.example/x.css', root: @root)).to be_nil
    end
  end
end
