# frozen_string_literal: true

require 'fileutils'
require 'date'
require 'minitest/autorun'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'yaml'

class BibLaTeXSampleTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SOURCE_FILES = %w[
    catalog.yml
    ch01.re
    ch02.re
    config.yml
    references.bib
    refs.re
    review-ext.rb
    review-bibref.csl
    review-bibtitle.csl
    style.css
  ].freeze

  def setup
    @workdir = Dir.mktmpdir('review-biblatex-sample-')
    SOURCE_FILES.each do |file|
      FileUtils.cp(File.join(ROOT, file), File.join(@workdir, file))
    end
  end

  def teardown
    FileUtils.rm_rf(@workdir)
  end

  def test_html_output
    run_review_compile('html')

    ch01 = read_output('ch01.html')
    assert_includes ch01, '<link rel="stylesheet" type="text/css" href="style.css" />'
    assert_includes ch01, '<span class="secno">第1章　</span>BibLaTeX sample'
    assert_includes ch01, "Sample and Prototype (2020: 20–22)"
    assert_includes ch01, '<div class="biblatex-list" data-biblist-id="ch01">'
    assert_includes ch01, 'id="biblatex-brown2022"'
    assert_includes ch01, 'id="biblatex-tanaka2021"'

    ch02 = read_output('ch02.html')
    assert_includes ch02, '翻訳書の日本語版タイトルは『翻訳された架空の都市論: 共有地図の実例』，第3版'
    assert_includes ch02, '原書名は<em>Imaginary Cities and Shared Maps: A Field Guide</em>'
    assert_includes ch02, '両方なら『翻訳された架空の都市論: 共有地図の実例』，第3版（原題: <em>Imaginary Cities and Shared Maps: A Field Guide</em>）'
    assert_includes ch02, '<div class="biblatex-list" data-biblist-id="ch02">'
    assert_includes ch02, 'id="biblatex-translation2020ja"'
    assert_includes ch02, '<em>Designing sample books: Practical patterns for examples</em>. 2nd ed.'
    assert_includes ch02, '『翻訳された架空の都市論: 共有地図の実例』，第3版，例示監訳，例示監修，藤田翼訳，見本翻訳社'
    assert_includes ch02, '原著: Imaginary Cities and Shared Maps: A Field Guide, 2016, Fictional Cartography Press'

    refs = read_output('refs.html')
    assert_includes refs, '<div class="biblatex-list">'
    assert_includes refs, 'id="biblatex-brown2022"'
    assert_includes refs, 'id="biblatex-translation2020ja"'
    assert_includes refs, 'id="biblatex-takahashi2021chapter"'
  end

  def test_latex_output
    run_review_compile('latex')

    ch01 = read_output('ch01.tex')
    assert_includes ch01, '\\chapter{BibLaTeX sample}'
    assert_includes ch01, 'Sample and Prototype (2020: 20--22)'
    assert_includes ch01, '\\begin{CSLReferences}{1}{0}'

    ch02 = read_output('ch02.tex')
    assert_includes ch02, '翻訳書の日本語版タイトルは『翻訳された架空の都市論: 共有地図の実例』，第3版'
    assert_includes ch02, '原書名は\\emph{Imaginary Cities and Shared Maps: A Field Guide}'
    assert_includes ch02, '両方なら『翻訳された架空の都市論: 共有地図の実例』，第3版（原題: \\emph{Imaginary Cities and Shared Maps: A Field Guide}）'
    assert_includes ch02, '\\emph{Designing sample books: Practical patterns for examples}. 2nd ed.'
    assert_includes ch02, '『翻訳された架空の都市論: 共有地図の実例』，第3版，例示監訳，例示監修，藤田翼訳，見本翻訳社'
    assert_includes ch02, '原著: Imaginary Cities and Shared Maps: A Field Guide, 2016, Fictional Cartography Press'
  end

  def test_script_does_not_embed_bibtitle_label
    refute_includes File.read(File.join(ROOT, 'review-ext.rb')), '原題'
  end

  def test_default_biblatex_styles
    config_path = File.join(@workdir, 'config.yml')
    config = YAML.load_file(config_path, permitted_classes: [Date])
    config.delete('biblatex')
    File.write(config_path, YAML.dump(config))

    run_review_compile('html')

    ch02 = read_output('ch02.html')
    assert_includes ch02, '原書名は<em>Imaginary Cities and Shared Maps: A Field Guide</em>'
    assert_includes ch02, '<div class="biblatex-list" data-biblist-id="ch02">'
  end

  private

  def run_review_compile(target)
    command = Shellwords.split(ENV.fetch('REVIEW_COMPILE', 'review-compile'))
    command += ['--target', target, '--directory', '.']
    stdout, stderr, status = Open3.capture3(*command, chdir: @workdir)
    assert status.success?, <<~MESSAGE
      review-compile failed for #{target}

      command: #{command.shelljoin}

      stdout:
      #{stdout}

      stderr:
      #{stderr}
    MESSAGE
  end

  def read_output(file)
    File.read(File.join(@workdir, file))
  end
end
