# frozen_string_literal: true

module Necropsy
  class ReferenceBarrier
    MAX_FILE_BYTES = 1_048_576
    MAX_MATCHES_PER_DEFINITION = 5
    MAX_SNIPPET_BYTES = 240
    SKIPPED_SAMPLE_LIMIT = 50
    BINARY_EXTENSIONS = %w[
      .7z .a .bundle .class .db .dll .dylib .eot .exe .gif .gz .ico .jar .jpeg .jpg .o .pdf .png .so .sqlite
      .tar .ttf .webp .woff .woff2 .zip
    ].freeze
    GENERATED_PATH_PARTS = %w[generated dist].freeze
    TOOL_METADATA_BASENAMES = %w[.necropsy.yml .necropsy_baseline.yml].freeze
    GENERATED_MARKER = /(?:@generated|automatically generated|generated file|do not edit)/i
    TOKEN_PATTERN = /[A-Za-z_][A-Za-z0-9_]*(?:[!?=](?![A-Za-z0-9_]))?/

    def initialize(graph:, project:, ignored_paths: [])
      @graph = graph
      @project = project
      @ignored_paths = Array(ignored_paths).compact.to_set { |path| File.expand_path(path, project.root) }
    end

    def apply(findings)
      @candidates = findings.reject { |finding| finding.blockers.any? }.map(&:node).sort_by(&:graph_id)
      @candidate_index = build_candidate_index
      @non_token_index = build_non_token_index
      @non_token_pattern = build_non_token_pattern
      @matches = Hash.new { |hash, key| hash[key] = [] }
      @skipped_counts = Hash.new(0)
      @skipped_samples = []
      @files_scanned = 0
      @truncated_matches = 0
      files = project.non_ruby_reference_files
      files.each { |file| scan_file(file) } unless candidates.empty?
      add_blockers
      record_diagnostic(files)
      matches.values.sum(&:length)
    end

    private

    attr_reader :graph, :project, :candidates, :candidate_index, :non_token_index, :non_token_pattern, :matches,
                :skipped_counts,
                :skipped_samples, :ignored_paths

    def build_candidate_index
      Hash.new { |hash, key| hash[key] = [] }.tap do |index|
        candidates.each do |node|
          reference_tokens(node.name).each { |token| index[token] << node }
        end
      end
    end

    def build_non_token_index
      candidates.select { |node| reference_tokens(node.name).empty? }.group_by(&:name)
    end

    def build_non_token_pattern
      return unless non_token_index.any?

      alternatives = Regexp.union(non_token_index.keys.sort_by { |name| -name.length }).source
      /(?<![[:alnum:]_])(?:#{alternatives})(?![[:alnum:]_])/u
    end

    def reference_tokens(name)
      return [] unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*[!?=]?\z/)

      [name, lower_camel_case(name)].uniq
    end

    def lower_camel_case(name)
      base = name.delete_suffix('!').delete_suffix('?').delete_suffix('=')
      suffix = name.delete_prefix(base)
      parts = base.split('_')
      return name if parts.length == 1

      "#{parts.first}#{parts.drop(1).map(&:capitalize).join}#{suffix}"
    end

    def scan_file(path)
      relative = project.relative_path(path)
      return skip(relative, :tool_metadata) if tool_metadata?(relative)
      return skip(relative, :generated) if generated_path?(relative)
      return skip(relative, :binary) if BINARY_EXTENSIONS.include?(File.extname(relative).downcase)
      return skip(relative, :oversized) if File.size(path) > MAX_FILE_BYTES

      bytes = File.binread(path, MAX_FILE_BYTES + 1)
      return skip(relative, :oversized) if bytes.bytesize > MAX_FILE_BYTES
      return skip(relative, :binary) if bytes.include?("\0")

      source = bytes.force_encoding(Encoding::UTF_8)
      return skip(relative, :binary) unless source.valid_encoding?
      return skip(relative, :generated) if generated_header?(source)

      @files_scanned += 1
      searchable_source(source, relative).each_line.with_index(1) do |line, line_number|
        scan_line(relative, line, line_number)
      end
    rescue SystemCallError => e
      skip(relative || path.to_s, :unreadable, error: e.class.name)
    end

    def generated_path?(relative)
      parts = relative.split(File::SEPARATOR)
      parts.intersect?(GENERATED_PATH_PARTS) || File.basename(relative).include?('.min.')
    end

    def generated_header?(source)
      source.each_line.first(20).take_while do |line|
        stripped = line.strip
        stripped.empty? || stripped.start_with?('#', '//', '--', ';', '<!--', '<%#', '/*', '*')
      end.any? { |line| line.match?(GENERATED_MARKER) }
    end

    def tool_metadata?(relative)
      return true if TOOL_METADATA_BASENAMES.include?(File.basename(relative))

      expanded = File.expand_path(relative, project.root)
      configured = [
        project.config.path,
        File.expand_path(project.config.baseline_path, project.root)
      ].compact.map { |path| File.expand_path(path) }
      configured.include?(expanded) || ignored_paths.include?(expanded)
    end

    def searchable_source(source, file)
      without_block_comments = source.gsub(%r{<%#.*?%>|<!--.*?-->|/\*.*?\*/}m) do |comment|
        comment.gsub(/[^\n]/, ' ')
      end
      return without_block_comments unless File.extname(file).downcase == '.erb'

      without_block_comments.gsub(/<%(?!#)(.*?)%>/m) do
        body = ::Regexp.last_match(1)
        stripped_body = body.each_line.map { |line| strip_comment(line, ['#']) }.join
        "<%#{stripped_body}%>"
      end
    end

    def scan_line(file, line, line_number)
      stripped = line.lstrip
      return if inline_comment_markers(file).any? { |marker| stripped.start_with?(marker) }

      searchable_line = strip_inline_comment(line, file)
      searchable_line.scan(TOKEN_PATTERN).uniq.each do |token|
        candidate_index.fetch(token, []).each do |node|
          kind = reference_kind(searchable_line, token, node)
          record_match(node, file, line_number, line, token, kind) if kind
        end
      end
      return unless non_token_pattern

      searchable_line.scan(non_token_pattern).uniq.each do |name|
        non_token_index.fetch(name).each do |node|
          kind = non_token_reference_kind(searchable_line, node)
          record_match(node, file, line_number, line, node.name, kind) if kind
        end
      end
    end

    def strip_inline_comment(line, file)
      strip_comment(line, inline_comment_markers(file))
    end

    def strip_comment(line, markers)
      quote = nil
      escaped = false
      line.each_char.with_index do |character, index|
        if quote
          if escaped
            escaped = false
          elsif character == '\\'
            escaped = true
          elsif character == quote
            quote = nil
          end
          next
        end

        if ['"', "'"].include?(character)
          quote = character
          next
        end
        next unless index.zero? || line[index - 1].match?(/\s/)

        marker = markers.find { |candidate| line[index, candidate.length] == candidate }
        if marker
          prefix = line[0...index]
          return line.end_with?("\n") ? "#{prefix}\n" : prefix
        end
      end
      line
    end

    def inline_comment_markers(file)
      extension = File.extname(file).downcase
      markers = []
      markers << '#' if %w[.bash .conf .env .gql .graphql .ini .properties .sh .toml .yaml .yml .zsh].include?(extension)
      markers << '//' if %w[.c .cc .cpp .css .gql .graphql .h .hpp .js .jsx .scss .ts .tsx].include?(extension)
      markers << '--' if extension == '.sql'
      markers << ';' if extension == '.ini'
      markers
    end

    def reference_kind(line, token, node)
      qualified_kind, remaining, qualified = qualified_reference(line, token, node)
      return qualified_kind if qualified_kind
      return if qualified && !direct_name_reference?(remaining, token)
      return 'symbol_or_string' if symbolic_or_string_reference?(remaining, token)

      token == node.name ? 'method_name' : 'method_name_camelized'
    end

    def qualified_reference(line, token, node)
      pattern = qualified_pattern(token)
      owners = line.scan(pattern).flatten
      return [nil, line, false] if owners.empty?

      expected = [node.owner, node.owner.to_s.split('::').last].compact.reject(&:empty?).uniq
      return ['qualified_owner', line, true] if owners.intersect?(expected)

      [nil, line.gsub(pattern, ' '), true]
    end

    def qualified_pattern(token)
      /(?<![A-Za-z0-9_:])([A-Z][A-Za-z0-9_:]*)(?:#|\.)#{Regexp.escape(token)}(?![A-Za-z0-9_])/
    end

    def symbolic_or_string_reference?(line, token)
      escaped = Regexp.escape(token)
      line.match?(/(?:(?<![A-Za-z0-9_:]):#{escaped}(?![A-Za-z0-9_])|["']#{escaped}["'])/)
    end

    def non_token_reference_kind(line, node)
      qualified_kind, remaining, qualified = qualified_reference(line, node.name, node)
      return qualified_kind if qualified_kind
      return if qualified && !direct_name_reference?(remaining, node.name)
      return 'symbol_or_string' if symbolic_or_string_reference?(remaining, node.name)
      return 'method_name' if direct_name_reference?(remaining, node.name)

      nil
    end

    def direct_name_reference?(line, name)
      line.match?(/(?<![[:alnum:]_])#{Regexp.escape(name)}(?![[:alnum:]_])/u)
    end

    def record_match(node, file, line_number, line, token, kind)
      node_matches = matches[node.graph_id]
      if node_matches.length >= MAX_MATCHES_PER_DEFINITION
        @truncated_matches += 1
        return
      end

      node_matches << {
        'file' => file,
        'line' => line_number,
        'snippet' => bounded_snippet(line),
        'match_kind' => kind,
        'matched_text' => token
      }
    end

    def bounded_snippet(line)
      snippet = line.strip.gsub(/\s+/, ' ')
      return snippet if snippet.bytesize <= MAX_SNIPPET_BYTES

      "#{snippet.byteslice(0, MAX_SNIPPET_BYTES).to_s.scrub}\u2026"
    end

    def skip(file, reason, error: nil)
      skipped_counts[reason.to_s] += 1
      return if skipped_samples.length >= SKIPPED_SAMPLE_LIMIT

      sample = { 'file' => file, 'reason' => reason.to_s }
      sample['error'] = error if error
      skipped_samples << sample
    end

    def add_blockers
      candidates.each do |node|
        matches.fetch(node.graph_id, []).each do |match|
          graph.add_blocker(reference_blocker(node, match))
        end
      end
    end

    def reference_blocker(node, match)
      Blocker.new(
        kind: :unparsed_external_reference,
        scope_kind: :definition,
        scope_value: node.graph_id,
        source: :non_ruby_reference_barrier,
        reason: "Unparsed non-Ruby text may reference #{node.symbol_id}",
        suggested_action: :inspect_external_reference,
        metadata: match.merge(
          'caller_domain' => reference_domain(match.fetch('file')),
          'message' => node.name,
          'symbol_id' => node.symbol_id,
          'definition_id' => node.graph_id
        )
      )
    end

    def reference_domain(relative)
      project.test_file?(File.join(project.root, relative)) ? 'test' : 'runtime'
    end

    def record_diagnostic(files)
      graph.observation['non_ruby_reference_barrier'] = {
        'scanner' => 'portable_ruby',
        'candidate_definitions' => candidates.length,
        'files_considered' => files.length,
        'files_scanned' => @files_scanned,
        'matched_definitions' => matches.count { |_definition_id, entries| entries.any? },
        'matches' => matches.values.sum(&:length),
        'truncated_matches' => @truncated_matches,
        'skipped_counts' => skipped_counts.sort.to_h,
        'skipped_samples' => skipped_samples.sort_by { |sample| [sample.fetch('file'), sample.fetch('reason')] }
      }
    end
  end
end
