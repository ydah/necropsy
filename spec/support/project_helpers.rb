# frozen_string_literal: true

require 'fileutils'

module ProjectHelpers
  def create_project(files: {}, config: nil)
    root = Dir.mktmpdir
    temporary_project_roots << root
    files.each { |path, contents| write_project_file(root, path, contents) }
    write_project_file(root, '.necropsy.yml', config.to_yaml) if config
    root
  end

  def with_project(files: {}, config: nil)
    Dir.mktmpdir do |root|
      files.each { |path, contents| write_project_file(root, path, contents) }
      write_project_file(root, '.necropsy.yml', config.to_yaml) if config
      yield root
    end
  end

  def write_project_file(root, path, contents)
    full_path = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def project_for(root, config_path: nil)
    config = Necropsy::Configuration.load(root: root, path: config_path)
    Necropsy::Project.new(root: root, config: config)
  end

  def scan_project(root, config_path: nil)
    project_for(root, config_path: config_path).scan_result
  end

  def graph_for_scan(scan_result)
    Necropsy::CallGraph.new(scan_result)
  end

  def graph_for_project(root, config_path: nil)
    graph_for_scan(scan_project(root, config_path: config_path))
  end

  def temporary_project_roots
    @temporary_project_roots ||= []
  end
end

RSpec.configure do |config|
  config.include ProjectHelpers

  config.after do
    temporary_project_roots.reverse_each do |root|
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end
  end
end
