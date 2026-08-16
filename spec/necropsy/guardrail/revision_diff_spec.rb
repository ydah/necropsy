# frozen_string_literal: true

require 'open3'
require 'necropsy/cli'

RSpec.describe Necropsy::Guardrail::RevisionDiff do
  it 'compares two Git revisions without mutating the repository worktree' do
    Dir.mktmpdir do |root|
      write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)
      write_project_file(root, 'app/sample.rb', "class Sample\n  def live\n    :live\n  end\nend\n")
      git_run(root, 'init', '-q')
      git_run(root, 'config', 'user.email', 'necropsy@example.test')
      git_run(root, 'config', 'user.name', 'Necropsy Test')
      git_run(root, 'add', '.')
      git_run(root, 'commit', '-qm', 'initial')
      base_revision = git_run(root, 'rev-parse', 'HEAD').strip

      write_project_file(root, 'app/removed.rb', "class Removed\n  def dead\n    :dead\n  end\nend\n")
      git_run(root, 'add', '.')
      git_run(root, 'commit', '-qm', 'add removed')
      head_revision = git_run(root, 'rev-parse', 'HEAD').strip
      before = Dir.children(root).sort

      result = described_class.compare(root: root, base_revision: base_revision, head_revision: head_revision)

      expect(result.dig('validation', 'comparable')).to be(true)
      expect(result.dig('base', 'name')).to eq('necropsy')
      expect(result.dig('head', 'name')).to eq('necropsy')
      expect(Dir.children(root).sort).to eq(before)
    end
  end

  it 'supports a revision base against the current worktree' do
    Dir.mktmpdir do |root|
      write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)
      write_project_file(root, 'app/sample.rb', "class Sample\n  def live\n    :live\n  end\nend\n")
      git_run(root, 'init', '-q')
      git_run(root, 'config', 'user.email', 'necropsy@example.test')
      git_run(root, 'config', 'user.name', 'Necropsy Test')
      git_run(root, 'add', '.')
      git_run(root, 'commit', '-qm', 'initial')
      base_revision = git_run(root, 'rev-parse', 'HEAD').strip
      write_project_file(root, 'app/current.rb', "class Current\n  def run\n    :run\n  end\nend\n")

      result = described_class.compare(root: root, base_revision: base_revision)

      expect(result.dig('validation', 'comparable')).to be(true)
      expect(result).to include('analysis_health_changed', 'public_surface_changed')

      status = nil
      expect do
        status = Necropsy::CLI.run(['diff', '--root', root, '--base', base_revision])
      end.to output(satisfy { |output| JSON.parse(output).dig('validation', 'comparable') == true }).to_stdout
      expect(status).to eq(0)
    end
  end

  it 'rejects symlinks in a Git revision before analysis' do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        write_project_file(root, '.necropsy.yml', { cache: { enabled: false } }.to_yaml)
        write_project_file(outside, 'outside.rb', "class Outside; end\n")
        File.symlink(File.join(outside, 'outside.rb'), File.join(root, 'linked.rb'))
        git_run(root, 'init', '-q')
        git_run(root, 'config', 'user.email', 'necropsy@example.test')
        git_run(root, 'config', 'user.name', 'Necropsy Test')
        git_run(root, 'add', '.')
        git_run(root, 'commit', '-qm', 'symlink')
        revision = git_run(root, 'rev-parse', 'HEAD').strip

        expect do
          described_class.compare(root: root, base_revision: revision)
        end.to raise_error(Necropsy::Error, /unsupported symlink/)
      end
    end
  end

  it 'does not pass option-like revision input to Git archive' do
    Dir.mktmpdir do |root|
      git_run(root, 'init', '-q')

      expect do
        described_class.compare(root: root, base_revision: '--output=/tmp/unsafe')
      end.to raise_error(Necropsy::Error, /Could not resolve Git revision/)
    end
  end

  def write_project_file(root, path, contents)
    full_path = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def git_run(root, *arguments)
    stdout, stderr, status = Open3.capture3('git', '-C', root, *arguments)
    raise "git failed: #{stderr}" unless status.success?

    stdout
  end
end
