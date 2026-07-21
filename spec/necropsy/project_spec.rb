# frozen_string_literal: true

RSpec.describe Necropsy::Project do
  it 'discovers Ruby, executable, rake, Rakefile, and gemspec sources while excluding generated directories' do
    files = {
      'app/model.rb' => 'class Model; end',
      'bin/tool' => "#!/usr/bin/env ruby\nputs :bin",
      'bin/shell-tool' => "#!/bin/sh\necho shell",
      'exe/tool' => "#!/usr/bin/ruby\nputs :exe",
      'Rakefile' => 'task :default',
      'tasks/build.rake' => 'task :build',
      'necropsy.gemspec' => 'Gem::Specification.new',
      'tmp/ignored.rb' => 'class Ignored; end',
      'vendor/ignored.rb' => 'class VendorIgnored; end',
      'app/services/coverage/report.rb' => 'class CoverageReport; end',
      'app/services/doc/render.rb' => 'class DocRender; end'
    }

    with_project(files: files) do |root|
      project = project_for(root)

      expect(project.ruby_files.map { |file| project.relative_path(file) }).to contain_exactly(
        'Rakefile',
        'app/model.rb',
        'app/services/coverage/report.rb',
        'app/services/doc/render.rb',
        'bin/tool',
        'exe/tool',
        'necropsy.gemspec',
        'tasks/build.rake'
      )
    end
  end

  it 'applies configured include and exclude path patterns' do
    with_project(
      files: {
        'app/models/kept.rb' => '',
        'app/models/skipped.rb' => '',
        'lib/ignored.rb' => ''
      },
      config: { paths: { include: ['app/**/*.rb'], exclude: ['**/skipped.rb'] } }
    ) do |root|
      project = project_for(root)

      expect(project.ruby_files.map { |file| project.relative_path(file) }).to eq(['app/models/kept.rb'])
    end
  end

  it 'classifies spec and test files as test sources' do
    with_project(files: { 'spec/example_spec.rb' => '', 'test/example_test.rb' => '',
                          'app/example.rb' => '' }) do |root|
      project = project_for(root)

      expect(project.test_file?(File.join(root, 'spec/example_spec.rb'))).to eq(true)
      expect(project.test_file?(File.join(root, 'test/example_test.rb'))).to eq(true)
      expect(project.test_file?(File.join(root, 'app/example.rb'))).to eq(false)
    end
  end
end
