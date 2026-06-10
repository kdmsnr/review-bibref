# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require 'rexml/document'
require 'rexml/xpath'
require 'strscan'
require 'tempfile'

ReVIEW::Compiler.definline :bibref
ReVIEW::Compiler.definline :bibtitle
ReVIEW::Compiler.defsingle :biblist, 0..1

module ReVIEW
  module BibTeXExt
    class Error < StandardError; end

    CitationItem = Struct.new(:key, keyword_init: true)
    CitationGroup = Struct.new(:source, :items, keyword_init: true)
    TitleRequest = Struct.new(:key, :mode, keyword_init: true)
    Style = Struct.new(:path, keyword_init: true)

    class CitationParser
      def self.parse(source)
        source = source.to_s.strip
        raise Error, '@<bibref> contains no key.' if source.empty?

        items = source.scan(/-?@([^\s,;\[\]]+)/).flatten.map { |key| CitationItem.new(key: key) }
        raise Error, '@<bibref> must use Pandoc citation syntax with @key.' if items.empty?

        CitationGroup.new(source: source, items: items)
      end
    end

    class KeyParser
      def self.parse(source, command_name)
        source = source.to_s.strip
        raise Error, "#{command_name} contains no key." if source.empty?

        match = source.match(/\A@([^\s,;\[\]]+)\z/)
        raise Error, "#{command_name} must use @key." unless match

        match[1]
      end
    end

    class TitleRequestParser
      MODES = {
        'title' => :title,
        'translated' => :title,
        'ja' => :title,
        'orig' => :original,
        'both' => :both
      }.freeze

      def self.parse(source, command_name)
        key_source, mode_source = source.to_s.split(',', 2).map { |part| part.to_s.strip }
        key = KeyParser.parse(key_source, command_name)
        mode = mode_source.to_s.empty? ? :title : MODES[mode_source.downcase]
        raise Error, "#{command_name} title mode must be title, orig, or both." unless mode

        TitleRequest.new(key: key, mode: mode)
      end
    end

    module TitleFormatter
      ARTICLE_LIKE_TYPES = %w[article inbook incollection inproceedings conference].freeze
      CJK_LANGS = %w[japanese ja ja-jp chinese zh korean ko].freeze

      def self.title(entry, mode:)
        case mode
        when :title
          entry_title(entry)
        when :original
          original_title(entry)
        when :both
          "#{entry_title(entry)}（原題: #{original_title(entry)}）"
        else
          raise Error, "unsupported bibtitle mode: #{mode}"
        end
      end

      def self.entry_title(entry)
        title = entry.field('title')
        raise Error, "bibtex entry has no title: #{entry.key}" unless title

        title = normalized_title(entry, title)
        return title unless cjk?(entry)

        article_like?(entry) ? "「#{title}」" : "『#{title}』"
      end

      def self.original_title(entry)
        title = entry.field('origtitle', 'originaltitle')
        raise Error, "bibtex entry has no origtitle: #{entry.key}" unless title

        strip_bibtex_protection(title)
      end

      def self.csl_json_title(entry)
        title = entry.field('title')
        return nil unless title
        return strip_bibtex_protection(title) if cjk?(entry)

        sentence_case_bibtex_title(title)
      end

      def self.normalized_title(entry, title)
        cjk?(entry) ? strip_bibtex_protection(title) : sentence_case_bibtex_title(title)
      end

      def self.cjk?(entry)
        CJK_LANGS.include?(entry.field('langid', 'language').to_s.downcase)
      end

      def self.article_like?(entry)
        ARTICLE_LIKE_TYPES.include?(entry.type)
      end

      def self.strip_bibtex_protection(title)
        title.to_s.delete('{}')
      end

      def self.sentence_case_bibtex_title(title)
        protected_depth = 0
        seen_letter = false
        output = +''
        title.each_char do |ch|
          case ch
          when '{'
            protected_depth += 1
            next
          when '}'
            protected_depth -= 1 if protected_depth.positive?
            next
          end

          if protected_depth.positive?
            output << ch
          elsif ch.match?(/[[:alpha:]]/)
            output << (seen_letter ? ch.downcase : ch)
            seen_letter = true
          else
            output << ch
          end
        end
        output
      end
    end

    class Database
      DEFAULT_FILES = ['references.bib'].freeze
      DEFAULT_STYLE = 'review.csl'

      def self.load(book)
        config = book.config['bibtex'] || {}
        files = config.key?('files') ? config['files'] : DEFAULT_FILES
        raise Error, 'bibtex.files must be a non-empty array.' if !files.is_a?(Array) || files.empty?

        style = resolve_style(book, config['style'])
        lang = config['lang']
        raise Error, 'bibtex.lang must be a non-empty string.' if lang && (!lang.is_a?(String) || lang.empty?)

        parser = Parser.new
        entries = {}
        bibliography_paths = []
        files.each do |file|
          raise Error, "absolute bibtex file path is not allowed: #{file}" if Pathname.new(file).absolute?

          path = File.join(book.contentdir, file)
          raise Error, "bibtex file is not found: #{file}" unless File.file?(path)

          bibliography_paths << path
          parser.parse(File.read(path, mode: 'rt:BOM|utf-8')).each do |entry|
            raise Error, "duplicated bibtex key: #{entry.key}" if entries.key?(entry.key)

            entries[entry.key] = entry
          end
        end

        database = new(entries, style, bibliography_paths: bibliography_paths, lang: lang)
        database.scan_book(book)
        database
      end

      def self.resolve_style(book, style)
        style ||= DEFAULT_STYLE
        raise Error, 'bibtex.style must be a non-empty string.' if !style.is_a?(String) || style.empty?
        raise Error, "absolute bibtex style path is not allowed: #{style}" if Pathname.new(style).absolute?

        path = File.join(book.contentdir, style)
        raise Error, "bibtex style file is not found: #{style}" unless File.file?(path)

        Style.new(path: path)
      end

      attr_reader :style, :bibliography_paths, :lang

      def initialize(entries, style, bibliography_paths:, lang:)
        @entries = entries
        @style = style
        @bibliography_paths = bibliography_paths
        @lang = lang
        @book_order = []
        @book_numbers = {}
        @chapter_order = Hash.new { |hash, key| hash[key] = [] }
        @chapter_numbers = Hash.new { |hash, key| hash[key] = {} }
      end

      def cite(chapter_id, source)
        group = CitationParser.parse(source)
        group.items.each { |item| register(chapter_id, item.key) }
        group
      end

      def entry(key)
        @entries.fetch(key) { raise Error, "unknown bibtex key: #{key}" }
      end

      def title(source, command_name: '@<bibtitle>')
        request = TitleRequestParser.parse(source, command_name)
        TitleFormatter.title(entry(request.key), mode: request.mode)
      end

      def citation_keys(scope:, chapter_id: nil)
        scope == :chapter ? @chapter_order[chapter_id.to_s] : @book_order
      end

      def render_citation(group, scope:, chapter_id: nil)
        processor.render_citation(group, scope: scope, chapter_id: chapter_id)
      end

      def render_bibliography(scope:, chapter_id: nil)
        processor.render_bibliography(scope: scope, chapter_id: chapter_id)
      end

      def render_latex_citation(group, scope:, chapter_id: nil)
        processor.render_latex_citation(group, scope: scope, chapter_id: chapter_id)
      end

      def render_latex_bibliography(scope:, chapter_id: nil)
        processor.render_latex_bibliography(scope: scope, chapter_id: chapter_id)
      end

      def scan_book(book)
        chapters = book.catalog ? book.contents : []
        chapters.each do |chapter|
          next unless chapter.content

          chapter.content.scan(/@<bibref>\{([^}]*)\}/) do |source|
            cite(chapter.id, source.first)
          end
        end
      end

      private

      def register(chapter_id, key)
        entry(key)
        unless @book_numbers.key?(key)
          @book_order << key
          @book_numbers[key] = @book_order.size
        end

        chapter_key = chapter_id.to_s
        return if @chapter_numbers[chapter_key].key?(key)

        @chapter_order[chapter_key] << key
        @chapter_numbers[chapter_key][key] = @chapter_order[chapter_key].size
      end

      def processor
        @processor ||= PandocProcessor.new(self)
      end
    end

    class PandocProcessor
      def initialize(database)
        @database = database
      end

      def render_citation(group, scope:, chapter_id: nil)
        html = run_pandoc(markdown_for_citation(group, scope: scope, chapter_id: chapter_id), target: :html)
        paragraphs = REXML::XPath.match(html_document(html), '/root/p')
        raise Error, 'csl processor did not render a citation.' if paragraphs.empty?

        inner_html(paragraphs.last)
      end

      def render_bibliography(scope:, chapter_id: nil)
        keys = @database.citation_keys(scope: scope, chapter_id: chapter_id)
        return '' if keys.empty?

        html = run_pandoc(markdown_for_bibliography(keys), target: :html)
        refs = REXML::XPath.first(html_document(html), '/root/div[@id="refs"]')
        raise Error, 'csl processor did not render a bibliography.' unless refs

        refs.attributes.delete('id')
        node_html(refs)
      end

      def render_latex_citation(group, scope:, chapter_id: nil)
        latex = run_pandoc(markdown_for_citation(group, scope: scope, chapter_id: chapter_id), target: :latex)
        extract_latex_citation(latex)
      end

      def render_latex_bibliography(scope:, chapter_id: nil)
        keys = @database.citation_keys(scope: scope, chapter_id: chapter_id)
        return '' if keys.empty?

        latex = run_pandoc(markdown_for_bibliography(keys), target: :latex)
        extract_latex_bibliography(latex)
      end

      private

      def markdown_for_citation(group, scope:, chapter_id:)
        keys = @database.citation_keys(scope: scope, chapter_id: chapter_id)
        blocks = keys.map { |key| "[@#{key}]" }
        blocks << group.source
        blocks << "::: {#refs}\n:::"
        "#{blocks.join("\n\n")}\n"
      end

      def markdown_for_bibliography(keys)
        blocks = keys.map { |key| "[@#{key}]" }
        blocks << "::: {#refs}\n:::"
        "#{blocks.join("\n\n")}\n"
      end

      def run_pandoc(markdown, target:)
        command = [
          ENV.fetch('REVIEW_BIBTEX_PANDOC', 'pandoc'),
          '-f', 'markdown',
          '-t', target.to_s,
          '--wrap=none',
          '--citeproc',
          "--csl=#{@database.style.path}",
          '--metadata=link-citations:false',
          "--bibliography=#{csl_json_bibliography.path}"
        ]
        command << "--metadata=lang:#{@database.lang}" if @database.lang

        stdout, stderr, status = Open3.capture3(*command, stdin_data: markdown)
        raise Error, "csl processor failed: #{stderr.strip}" unless status.success?

        stdout
      rescue Errno::ENOENT
        raise Error, 'pandoc command is required for CSL rendering.'
      end

      def html_document(html)
        REXML::Document.new("<root>#{html}</root>")
      rescue REXML::ParseException => e
        raise Error, "csl processor returned invalid html: #{e.message}"
      end

      def extract_latex_citation(latex)
        before_refs = latex.split(/\\protect\\phantomsection\\label\{refs\}\n|\\begin\{CSLReferences\}/, 2).first.to_s
        paragraphs = before_refs.strip.split(/\n{2,}/).reject(&:empty?)
        raise Error, 'csl processor did not render a citation.' if paragraphs.empty?

        paragraphs.last.strip
      end

      def extract_latex_bibliography(latex)
        start = latex.index('\begin{CSLReferences}')
        raise Error, 'csl processor did not render a bibliography.' unless start

        "#{latex[start, latex.length].strip}\n"
      end

      def inner_html(element)
        element.children.map { |child| node_html(child) }.join
      end

      def node_html(node)
        output = +''
        REXML::Formatters::Default.new.write(node, output)
        output
      end

      def csl_json_bibliography
        @csl_json_bibliography ||= CSLJsonBibliography.new(@database)
      end
    end

    class CSLJsonBibliography
      LANGID_TO_LANGUAGE = {
        'japanese' => 'ja-JP',
        'ja' => 'ja-JP',
        'ja-jp' => 'ja-JP',
        'english' => 'en-US',
        'en' => 'en-US',
        'en-us' => 'en-US',
        'chinese' => 'zh-CN',
        'zh' => 'zh-CN',
        'korean' => 'ko-KR',
        'ko' => 'ko-KR'
      }.freeze

      def initialize(database)
        @database = database
      end

      def path
        tempfile.path
      end

      def items
        @items ||= @database.bibliography_paths.flat_map { |path| convert_file(path) }.map { |item| normalize_item(item) }
      end

      private

      def tempfile
        @tempfile ||= begin
          file = Tempfile.new(['review-bibtex-ext-', '.json'])
          file.write(JSON.pretty_generate(items))
          file.write("\n")
          file.flush
          file
        end
      end

      def convert_file(path)
        stdout, stderr, status = Open3.capture3(pandoc_command, '-f', 'biblatex', '-t', 'csljson', path)
        raise Error, "bibtex to csl json conversion failed: #{stderr.strip}" unless status.success?

        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise Error, "bibtex to csl json conversion returned invalid json: #{e.message}"
      rescue Errno::ENOENT
        raise Error, 'pandoc command is required for CSL rendering.'
      end

      def normalize_item(item)
        id = item['id'].to_s
        entry = @database.entry(id)
        item = item.dup
        normalize_language(item, entry)
        normalize_title(item, entry)
        item
      end

      def normalize_language(item, entry)
        langid = entry.field('langid', 'language').to_s.downcase
        language = LANGID_TO_LANGUAGE[langid]
        item['language'] = language if language
      end

      def normalize_title(item, entry)
        title = TitleFormatter.csl_json_title(entry)
        item['title'] = title if title
      end

      def pandoc_command
        ENV.fetch('REVIEW_BIBTEX_PANDOC', 'pandoc')
      end
    end

    class Entry
      attr_reader :type, :key, :fields

      def initialize(type:, key:, fields:)
        @type = type
        @key = key
        @fields = fields
      end

      def field(*names)
        names.each do |name|
          value = @fields[name.to_s.downcase]
          return value if value && !value.empty?
        end
        nil
      end
    end

    class Parser
      def parse(source)
        scanner = StringScanner.new(source)
        entries = []
        until scanner.eos?
          scanner.scan_until(/@/)
          break if scanner.eos?

          type = scanner.scan(/[A-Za-z]+/).to_s.downcase
          skip_space(scanner)
          opener = scanner.getch
          next unless ['{', '('].include?(opener)

          body = read_entry_body(scanner, opener)
          next if %w[comment preamble string].include?(type)

          entries << parse_entry(type, body)
        end
        entries
      end

      private

      def parse_entry(type, body)
        key, fields_source = split_top_level(body, ',')
        key = key.to_s.strip
        raise Error, 'bibtex entry key is empty.' if key.empty?

        Entry.new(type: type, key: key, fields: parse_fields(fields_source.to_s))
      end

      def parse_fields(source)
        scanner = StringScanner.new(source)
        fields = {}
        until scanner.eos?
          skip_delimiters(scanner)
          break if scanner.eos?

          name = scanner.scan(/[A-Za-z][A-Za-z0-9_-]*/)
          raise Error, "invalid bibtex field near: #{scanner.rest}" unless name
          name = name.downcase

          skip_space(scanner)
          raise Error, "missing '=' for bibtex field: #{name}" unless scanner.getch == '='

          skip_space(scanner)
          fields[name] = normalize_value(read_value(scanner))
          skip_delimiters(scanner)
        end
        fields
      end

      def read_value(scanner)
        case scanner.peek(1)
        when '{'
          scanner.getch
          read_braced_value(scanner)
        when '"'
          scanner.getch
          read_quoted_value(scanner)
        else
          scanner.scan(/[^,]+/).to_s
        end
      end

      def read_entry_body(scanner, opener)
        closer = opener == '{' ? '}' : ')'
        brace_depth = opener == '{' ? 1 : 0
        quote = false
        buffer = +''
        until scanner.eos?
          ch = scanner.getch
          if quote
            quote = false if ch == '"'
            buffer << ch
            next
          end

          if ch == '"'
            quote = true
          elsif ch == '{'
            brace_depth += 1
          elsif ch == '}'
            brace_depth -= 1
            return buffer if opener == '{' && brace_depth.zero?
          elsif ch == closer && opener == '(' && brace_depth.zero?
            return buffer
          end
          buffer << ch
        end
        raise Error, 'unterminated bibtex entry.'
      end

      def read_braced_value(scanner)
        depth = 1
        buffer = +''
        until scanner.eos?
          ch = scanner.getch
          if ch == '{'
            depth += 1
          elsif ch == '}'
            depth -= 1
            return buffer if depth.zero?
          end
          buffer << ch
        end
        raise Error, 'unterminated braced bibtex value.'
      end

      def read_quoted_value(scanner)
        buffer = +''
        until scanner.eos?
          ch = scanner.getch
          return buffer if ch == '"'

          buffer << ch
        end
        raise Error, 'unterminated quoted bibtex value.'
      end

      def split_top_level(source, delimiter)
        depth = 0
        quote = false
        source.each_char.with_index do |ch, index|
          if quote
            quote = false if ch == '"'
            next
          end

          case ch
          when '"'
            quote = true
          when '{'
            depth += 1
          when '}'
            depth -= 1
          when delimiter
            return [source[0...index], source[(index + 1)..]] if depth.zero?
          end
        end
        [source, nil]
      end

      def normalize_value(value)
        value.to_s.gsub(/\s+/, ' ').strip
      end

      def skip_space(scanner)
        scanner.skip(/\s*/)
      end

      def skip_delimiters(scanner)
        scanner.skip(/[\s,]*/)
      end
    end

    module BuilderSupport
      def bibtex_ext_database
        @book.cache.fetch(:bibtex_ext_database) do
          ReVIEW::BibTeXExt::Database.load(@book)
        end
      end

      def bibtex_ext_reference_scope
        if bibtex_ext_chapter_list_location(@chapter.id)
          [:chapter, @chapter.id]
        else
          [:book, nil]
        end
      end

      def bibtex_ext_biblist_scope(chapter_id)
        app_error '//biblist[] is not allowed.' if chapter_id == ''

        scope = chapter_id ? :chapter : :book
        bibtex_ext_validate_chapter_id(chapter_id) if chapter_id
        [scope, chapter_id]
      end

      def bibtex_ext_validate_chapter_id(chapter_id)
        return if @book.chapter_index.key?(chapter_id)

        app_error "unknown biblist id: #{chapter_id}"
      end

      def bibtex_ext_chapter_list_location(chapter_id)
        bibtex_ext_list_locations_in_book.find { |candidate| candidate[:scope] == :chapter && candidate[:chapter_id] == chapter_id }
      end

      def bibtex_ext_list_locations_in_book
        @book.cache.fetch(:bibtex_ext_list_locations) do
          chapters = @book.catalog ? @book.contents : [@chapter]
          chapters.each_with_object([]) do |chapter, scopes|
            next unless chapter.content

            chapter.content.each_line do |line|
              match = line.match(/\A\/\/biblist(?:\[(.*?)\])?\s*\z/)
              next unless match

              scopes << { chapter: chapter, chapter_id: match[1], scope: match[1] ? :chapter : :book }
            end
          end
        end
      end
    end
  end
end

class ReVIEW::HTMLBuilder
  include ReVIEW::BibTeXExt::BuilderSupport

  def inline_bibref(source)
    db = bibtex_ext_database
    group = db.cite(@chapter.id, source)
    scope, chapter_id = bibtex_ext_reference_scope
    db.render_citation(group, scope: scope, chapter_id: chapter_id).gsub(/id=(["'])ref-([^"']+)\1/) do
      %Q(id="bibtex-#{normalize_id(Regexp.last_match(2))}")
    end
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end

  def inline_bibtitle(source)
    escape(bibtex_ext_database.title(source))
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end

  def biblist(chapter_id = nil)
    scope, chapter_id = bibtex_ext_biblist_scope(chapter_id)
    bibliography = bibtex_ext_database.render_bibliography(scope: scope, chapter_id: chapter_id)
    bibliography = bibliography.gsub(/id=(["'])ref-([^"']+)\1/) { %Q(id="bibtex-#{normalize_id(Regexp.last_match(2))}") }
    puts %Q(<div class="bibtex-list"#{%Q( data-biblist-id="#{escape(chapter_id)}") if chapter_id}>)
    puts bibliography unless bibliography.empty?
    puts '</div>'
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end
end

class ReVIEW::LATEXBuilder
  include ReVIEW::BibTeXExt::BuilderSupport

  def inline_bibref(source)
    db = bibtex_ext_database
    group = db.cite(@chapter.id, source)
    scope, chapter_id = bibtex_ext_reference_scope
    db.render_latex_citation(group, scope: scope, chapter_id: chapter_id)
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end

  def inline_bibtitle(source)
    escape(bibtex_ext_database.title(source))
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end

  def biblist(chapter_id = nil)
    scope, chapter_id = bibtex_ext_biblist_scope(chapter_id)
    bibliography = bibtex_ext_database.render_latex_bibliography(scope: scope, chapter_id: chapter_id)
    return if bibliography.empty?

    puts bibtex_ext_latex_csl_definitions
    puts bibliography
  rescue ReVIEW::BibTeXExt::Error => e
    app_error e.message
  end

  def bibtex_ext_latex_csl_definitions
    return '' if @bibtex_ext_latex_csl_definitions

    @bibtex_ext_latex_csl_definitions = true
    <<~'TEX'
      \makeatletter
      \providecommand{\citeproctext}{}
      \providecommand{\citeproc}[2]{%
        \begingroup\def\citeproctext{#2}\cite{#1}\endgroup}
      \@ifundefined{cslhangindent}{\newlength{\cslhangindent}}{}
      \setlength{\cslhangindent}{1.5em}
      \@ifundefined{csllabelwidth}{\newlength{\csllabelwidth}}{}
      \setlength{\csllabelwidth}{3em}
      \@ifundefined{CSLReferences}{%
        \newenvironment{CSLReferences}[2]{%
          \begin{list}{}{%
            \setlength{\itemindent}{0pt}%
            \setlength{\leftmargin}{0pt}%
            \setlength{\parsep}{0pt}%
            \ifodd #1%
              \setlength{\leftmargin}{\cslhangindent}%
              \setlength{\itemindent}{-1\cslhangindent}%
            \fi%
            \setlength{\itemsep}{#2\baselineskip}}}%
          {\end{list}}%
      }{}
      \providecommand{\CSLBlock}[1]{\hfill\break\parbox[t]{\linewidth}{\strut\ignorespaces#1\strut}}
      \providecommand{\CSLLeftMargin}[1]{\parbox[t]{\csllabelwidth}{\strut#1\strut}}
      \providecommand{\CSLRightInline}[1]{\parbox[t]{\dimexpr\linewidth-\csllabelwidth\relax}{\strut#1\strut}}
      \providecommand{\CSLIndent}[1]{\hspace{\cslhangindent}#1}
      \makeatother
    TEX
  end
end

class ReVIEW::Builder
  def inline_bibref(_source)
    ''
  end

  def inline_bibtitle(_source)
    ''
  end

  def biblist(_chapter_id = nil)
  end
end
