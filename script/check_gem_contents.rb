# frozen_string_literal: true

require 'rubygems/package'

package_path = ARGV.first || Dir['necropsy-*.gem'].max_by { |path| File.mtime(path) }
abort 'No built gem was found' unless package_path

spec = Gem::Package.new(package_path).spec
allowed = %r{\A(?:lib/[^/].*\.rb|exe/[^/]+|schema/[^/]+\.json|README\.md|CHANGELOG\.md|LICENSE\.txt)\z}
unexpected = spec.files.grep_v(allowed)
required = %w[README.md CHANGELOG.md LICENSE.txt schema/necropsy-report-v2.schema.json]
missing = required.reject { |path| spec.files.include?(path) }

abort "Unexpected files in #{package_path}: #{unexpected.join(', ')}" unless unexpected.empty?
abort "Missing required files in #{package_path}: #{missing.join(', ')}" unless missing.empty?

puts "Gem contents OK (#{package_path}: #{spec.files.length} files)"
