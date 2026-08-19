# frozen_string_literal: true

require_relative 'lib/necropsy/version'

Gem::Specification.new do |spec|
  spec.name = 'necropsy'
  spec.version = Necropsy::VERSION
  spec.authors = ['Yudai Takada']
  spec.email = ['t.yudai92@gmail.com']

  spec.summary = 'Hybrid dead-code detection for Ruby projects.'
  spec.description = 'Necropsy combines static call-graph reachability, optional dynamic evidence, and CI guardrails for Ruby dead-code detection.'
  spec.homepage = 'https://github.com/ydah/necropsy'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'
  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir[
    'lib/**/*.rb',
    'exe/*',
    'schema/**/*.json',
    'README.md',
    'CHANGELOG.md',
    'LICENSE.txt'
  ].select { |path| File.file?(path) }.sort
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'prism', '>= 1.0', '< 2.0'
end
