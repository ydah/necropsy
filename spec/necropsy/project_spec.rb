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
      expect(project.reference_ruby_files.map { |file| project.relative_path(file) }).to contain_exactly(
        'app/models/kept.rb', 'app/models/skipped.rb', 'lib/ignored.rb'
      )
    end
  end

  it 'separates analyze Ruby files from repository-wide Ruby and non-Ruby references' do
    with_project(
      files: {
        'lib/analyzed.rb' => 'class Analyzed; end',
        'exe/reference' => "#!/usr/bin/env ruby\nAnalyzed.new",
        'config/jobs.yml' => "job: Analyzed\n"
      },
      config: { paths: { analyze: ['lib/**'], reference: ['**/*'] } }
    ) do |root|
      project = project_for(root)

      expect(project.ruby_files.map { |file| project.relative_path(file) }).to eq(['lib/analyzed.rb'])
      expect(project.reference_ruby_files.map { |file| project.relative_path(file) }).to contain_exactly(
        'exe/reference', 'lib/analyzed.rb'
      )
      expect(project.reference_files.map { |file| project.relative_path(file) }).to include(
        '.necropsy.yml', 'config/jobs.yml', 'exe/reference', 'lib/analyzed.rb'
      )
      expect(project.source_domains).to eq(
        'lib/analyzed.rb' => :analyze,
        'exe/reference' => :reference
      )
      expect(project.scope_diagnostics).to include(
        'analyze_file_count' => 1,
        'reference_file_count' => 4,
        'reference_only_ruby_files' => ['exe/reference']
      )
    end
  end

  it 'preserves conventional default analysis while treating other Ruby sources as references' do
    with_project(
      files: {
        'lib/analyzed.rb' => 'class Analyzed; end',
        'scripts/caller' => "#!/usr/bin/env ruby\nAnalyzed.new",
        '.hidden.rb' => 'class HiddenReference; end'
      }
    ) do |root|
      project = project_for(root)

      expect(project.ruby_files.map { |file| project.relative_path(file) }).to eq(['lib/analyzed.rb'])
      expect(project.reference_ruby_files.map { |file| project.relative_path(file) }).to contain_exactly(
        '.hidden.rb', 'lib/analyzed.rb', 'scripts/caller'
      )
      expect(project.source_domains).to eq(
        'lib/analyzed.rb' => :analyze,
        '.hidden.rb' => :reference,
        'scripts/caller' => :reference
      )
    end
  end

  it 'diagnoses and blocks when non-test Ruby callers fall outside the reference scope' do
    with_project(
      files: {
        'lib/target.rb' => 'class Target; def call; end; end',
        'app/excluded_caller.rb' => 'Target.new.call',
        'spec/excluded_spec.rb' => 'Target.new.call'
      },
      config: { paths: { analyze: ['lib/**'], reference: ['lib/**'] } }
    ) do |root|
      project = project_for(root)
      diagnostic = nil

      expect { diagnostic = project.scope_diagnostics }.to output(
        %r{paths.reference excludes Ruby files.*app/excluded_caller.rb.*Findings are blocked}m
      ).to_stderr
      expect(diagnostic.fetch('potential_callers_outside_reference')).to eq(
        'count' => 2,
        'runtime_count' => 1,
        'samples' => ['app/excluded_caller.rb', 'spec/excluded_spec.rb']
      )
      expect(project.scope_blockers).to contain_exactly(
        have_attributes(
          kind: :reference_scope_incomplete,
          scope_kind: :global,
          suggested_action: :expand_reference_scope
        )
      )
    end
  end

  it 'rejects symlinks so reference discovery cannot escape the repository' do
    Dir.mktmpdir do |outside|
      outside_source = File.join(outside, 'outside.rb')
      File.write(outside_source, 'class Outside; end')
      with_project(files: { 'lib/inside.rb' => 'class Inside; end' }) do |root|
        FileUtils.mkdir_p(File.join(root, 'linked'))
        File.symlink(outside_source, File.join(root, 'linked/outside.rb'))
        project = project_for(root)

        expect(project.reference_files.map { |file| project.relative_path(file) }).not_to include(
          'linked/outside.rb'
        )
        expect(project.scope_diagnostics.fetch('ignored_symlinks')).to include('linked/outside.rb')
      end
    end
  end

  it 'reads only a bounded prefix when classifying extensionless reference files' do
    with_project(files: { 'data/payload' => "not ruby\n#{'x' * 1_024}" }) do |root|
      expect(File).to receive(:binread).with(File.join(root, 'data/payload'), 256).and_call_original

      project_for(root).reference_ruby_files
    end
  end

  it 'does not treat an empty extensionless file as a Ruby source' do
    with_project(files: { 'data/empty' => '' }) do |root|
      expect(project_for(root).reference_ruby_files).to be_empty
    end
  end

  it 'warns when scan includes exclude potential entry points' do
    with_project(
      files: { 'lib/sample.rb' => '', 'exe/sample' => "#!/usr/bin/env ruby\n", 'spec/sample_spec.rb' => '' },
      config: { paths: { include: ['lib/**'] } }
    ) do |root|
      project = project_for(root)

      expect { project.ruby_files }.to output(
        %r{paths.include excludes.*exe/sample.*spec/sample_spec.rb.*report.include}m
      ).to_stderr
      expect(project.scope_diagnostics.fetch('potential_entry_points_outside_analyze')).to contain_exactly(
        { 'file' => 'exe/sample', 'reference_status' => 'reference_only' },
        { 'file' => 'spec/sample_spec.rb', 'reference_status' => 'reference_only' }
      )
    end
  end

  it 'identifies paths.exclude as the source of an excluded entry-point warning' do
    with_project(
      files: { 'lib/sample.rb' => '', 'exe/sample' => "#!/usr/bin/env ruby\n" },
      config: { paths: { exclude: ['exe/**'] } }
    ) do |root|
      expect { project_for(root).ruby_files }.to output(
        %r{paths.exclude excludes.*exe/sample.*report.include}m
      ).to_stderr
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
