# frozen_string_literal: true

module Necropsy
  class ReferenceBarrier
    MAX_FILE_BYTES = 1_048_576
    MAX_STREAM_FILE_BYTES = 16_777_216
    MAX_TOTAL_SCAN_BYTES = 67_108_864
    MAX_TOTAL_MATCHES = 10_000
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
    UNSAFE_SKIP_REASONS = %i[generated oversized unreadable scan_budget match_budget].freeze
    COMMON_SHORT_NAMES = %w[call create destroy edit index new run show update].freeze
    REFERENCE_DSL_KEYS = %w[action callback command function handler method perform task].freeze
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
      @unsafe_runtime_skips = []
      @files_scanned = 0
      @files_streamed = 0
      @bytes_scanned = 0
      @total_matches = 0
      @truncated_matches = 0
      files = project.non_ruby_reference_files
      unless candidates.empty?
        files.each do |file|
          if @match_budget_exceeded
            record_match_budget(project.relative_path(file))
          else
            scan_file(file)
          end
        end
      end
      add_blockers
      unsafe_blockers = add_unsafe_skip_blocker
      record_diagnostic(files)
      matches.values.sum(&:length) + unsafe_blockers
    end

    private

    attr_reader :graph, :project, :candidates, :candidate_index, :non_token_index, :non_token_pattern, :matches,
                :skipped_counts,
                :skipped_samples, :ignored_paths, :unsafe_runtime_skips

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

      size = File.size(path)
      return skip(relative, :oversized) if size > MAX_STREAM_FILE_BYTES
      return skip(relative, :scan_budget) if @bytes_scanned + size > MAX_TOTAL_SCAN_BYTES
      return scan_large_file(path, relative, size) if size > MAX_FILE_BYTES

      bytes = File.binread(path, MAX_FILE_BYTES + 1)
      return skip(relative, :oversized) if bytes.bytesize > MAX_FILE_BYTES
      return skip(relative, :binary) if bytes.include?("\0")

      source = bytes.force_encoding(Encoding::UTF_8)
      return skip(relative, :binary) unless source.valid_encoding?
      return skip(relative, :generated) if generated_header?(source)

      @bytes_scanned += bytes.bytesize
      @files_scanned += 1
      original_lines = source.lines
      searchable_source(source, relative).each_line.with_index(1) do |line, line_number|
        scan_line(relative, line, line_number, display_line: original_lines.fetch(line_number - 1, line))
        break if @match_budget_exceeded
      end
      record_match_budget(relative) if @match_budget_exceeded
    rescue SystemCallError => e
      skip(relative || path.to_s, :unreadable, error: e.class.name)
    end

    def scan_large_file(path, relative, size)
      header = []
      valid = true
      File.open(path, 'rb') do |io|
        io.each_line.with_index(1) do |bytes, line_number|
          source = bytes.force_encoding(Encoding::UTF_8)
          valid &&= !bytes.include?("\0") && source.valid_encoding?
          header << source.dup if line_number <= 20
        end
      end
      return skip(relative, :binary) unless valid
      return skip(relative, :generated) if generated_header?(header.join)

      @bytes_scanned += size
      @files_scanned += 1
      @files_streamed += 1
      File.open(path, 'r:UTF-8') do |io|
        io.each_line.with_index(1) do |line, line_number|
          scan_line(relative, searchable_source(line, relative), line_number, display_line: line)
          break if @match_budget_exceeded
        end
      end
      record_match_budget(relative) if @match_budget_exceeded
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

      EmbeddedRuby.extract(without_block_comments)
    end

    def scan_line(file, line, line_number, display_line: line)
      stripped = line.lstrip
      return if inline_comment_markers(file).any? { |marker| stripped.start_with?(marker) }

      searchable_line = strip_inline_comment(line, file)
      searchable_line.scan(TOKEN_PATTERN).uniq.each do |token|
        candidate_index.fetch(token, []).each do |node|
          kind = reference_kind(searchable_line, token, node, file)
          record_match(node, file, line_number, display_line, token, kind) if kind
        end
      end
      return unless non_token_pattern

      searchable_line.scan(non_token_pattern).uniq.each do |name|
        non_token_index.fetch(name).each do |node|
          kind = non_token_reference_kind(searchable_line, node)
          record_match(node, file, line_number, display_line, node.name, kind) if kind
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

    def reference_kind(line, token, node, file)
      qualified_kind, remaining, qualified = qualified_reference(line, token, node)
      return qualified_kind if qualified_kind
      return if qualified && !direct_name_reference?(remaining, token)
      return 'symbol_or_string' if symbolic_or_string_reference?(remaining, token)
      return 'structured_reference' if common_name?(node.name) && structured_reference?(remaining, token, file)
      return if common_name?(node.name)

      token == node.name ? 'method_name' : 'method_name_camelized'
    end

    def common_name?(name)
      COMMON_SHORT_NAMES.include?(name)
    end

    def structured_reference?(line, token, file)
      return true if File.extname(file).downcase == '.erb' && line.include?('<%')

      keys = REFERENCE_DSL_KEYS.join('|')
      line.match?(/(?:\A|[,{\s])(?:#{keys})\s*[:=]\s*#{Regexp.escape(token)}(?![A-Za-z0-9_])/i)
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
      if @total_matches >= MAX_TOTAL_MATCHES
        @match_budget_exceeded = true
        return
      end

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
      @total_matches += 1
    end

    def bounded_snippet(line)
      snippet = line.strip.gsub(/\s+/, ' ')
      return snippet if snippet.bytesize <= MAX_SNIPPET_BYTES

      "#{snippet.byteslice(0, MAX_SNIPPET_BYTES).to_s.scrub}\u2026"
    end

    def skip(file, reason, error: nil)
      skipped_counts[reason.to_s] += 1
      sample = { 'file' => file, 'reason' => reason.to_s }
      sample['error'] = error if error
      unsafe_runtime_skips << sample if unsafe_skip?(file, reason)
      return if skipped_samples.length >= SKIPPED_SAMPLE_LIMIT

      skipped_samples << sample
    end

    def record_match_budget(file)
      return if @match_budget_recorded

      @match_budget_recorded = true
      skip(file, :match_budget)
    end

    def unsafe_skip?(file, reason)
      UNSAFE_SKIP_REASONS.include?(reason.to_sym) && reference_domain(file) == 'runtime'
    end

    def add_unsafe_skip_blocker
      return 0 if unsafe_runtime_skips.empty?

      graph.add_blocker(Blocker.new(
                          kind: :reference_scan_incomplete,
                          scope_kind: :global,
                          scope_value: '*',
                          source: :non_ruby_reference_barrier,
                          reason: "#{unsafe_runtime_skips.length} runtime reference files could not be searched safely",
                          suggested_action: :review_reference_scope,
                          metadata: {
                            'caller_domain' => 'runtime',
                            'skipped_file_count' => unsafe_runtime_skips.length,
                            'skipped_counts' => unsafe_skip_counts,
                            'files' => unsafe_runtime_skips.first(SKIPPED_SAMPLE_LIMIT)
                          }
                        ))
      1
    end

    def unsafe_skip_counts
      unsafe_runtime_skips.group_by { |sample| sample.fetch('reason') }.transform_values(&:length)
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
        'files_streamed' => @files_streamed,
        'bytes_scanned' => @bytes_scanned,
        'matched_definitions' => matches.count { |_definition_id, entries| entries.any? },
        'matches' => matches.values.sum(&:length),
        'truncated_matches' => @truncated_matches,
        'skipped_counts' => skipped_counts.sort.to_h,
        'skipped_samples' => skipped_samples.sort_by { |sample| [sample.fetch('file'), sample.fetch('reason')] }
      }
    end
  end
end
