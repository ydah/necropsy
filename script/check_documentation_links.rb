#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'pathname'

ROOT = Pathname(__dir__).parent
MARKDOWN_LINK = /\[[^\]]+\]\(([^)\s]+)(?:\s+[^)]*)?\)/
IGNORED_SCHEMES = %w[http:// https:// mailto:].freeze

tracked_markdown, status = Open3.capture2('git', 'ls-files', '--cached', '--others', '--exclude-standard', '--', '*.md')
abort 'unable to list Markdown files' unless status.success?

errors = []

tracked_markdown.lines.map(&:chomp).each do |relative_file|
  file = ROOT.join(relative_file)
  content = file.read

  content.to_enum(:scan, MARKDOWN_LINK).each do
    href = Regexp.last_match(1).delete_prefix('<').delete_suffix('>')
    next if href.empty? || href.start_with?('#') || IGNORED_SCHEMES.any? { |scheme| href.start_with?(scheme) }

    target = href.split('#', 2).first
    next if target.empty?

    resolved = (file.dirname + target).cleanpath
    next if resolved.file? || resolved.directory?

    errors << "#{relative_file}:#{content[0...Regexp.last_match.begin(0)].count("\n") + 1}: #{href} -> #{resolved.relative_path_from(ROOT)}"
  end
end

if errors.empty?
  puts "Documentation links OK (#{tracked_markdown.lines.count} Markdown files)"
else
  warn errors.join("\n")
  exit 1
end
