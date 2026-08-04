# frozen_string_literal: true

RSpec.describe Necropsy::AstScanner do
  def definitions(scan, symbol_id)
    scan.nodes.select { |node| node.symbol_id == symbol_id }
  end

  def scan_in_order(root, files)
    project = project_for(root)
    described_class.new(project: project, files: files.map { |file| File.join(root, file) }).scan
  end

  it 'preserves reopened definitions across files and gives their call sites physical callers' do
    files = {
      'lib/first.rb' => "class Reopened\n  def call\n    first_target\n  end\nend\n",
      'lib/second.rb' => "class Reopened\n  def call\n    second_target\n  end\nend\n"
    }

    with_project(files: files) do |root|
      scan = scan_project(root)
      reopened = definitions(scan, 'Reopened#call')

      expect(reopened.map(&:file)).to eq(%w[lib/first.rb lib/second.rb])
      expect(reopened.map(&:graph_id).uniq.length).to eq(2)
      expect(scan.call_sites.select { |site| %w[first_target second_target].include?(site.message) }).to contain_exactly(
        have_attributes(caller_id: reopened[0].graph_id, message: 'first_target'),
        have_attributes(caller_id: reopened[1].graph_id, message: 'second_target')
      )
    end
  end

  it 'assigns deterministic ordinals to identical definitions in one file' do
    source = <<~RUBY
      class Repeated
        def call
          helper
        end

        def call
          helper
        end
      end
    RUBY

    with_project(files: { 'lib/repeated.rb' => source }) do |root|
      repeated = definitions(scan_project(root), 'Repeated#call')

      expect(repeated.map(&:ordinal)).to eq([1, 2])
      expect(repeated.map(&:body_digest).uniq.length).to eq(1)
      expect(repeated.map(&:graph_id).uniq.length).to eq(2)
    end
  end

  it 'uses physical caller ids for aliases and module-function copies' do
    source = <<~RUBY
      module Tools
        def work
          helper
        end
        alias backup work
        module_function :work
      end
    RUBY

    with_project(files: { 'lib/tools.rb' => source }) do |root|
      scan = scan_project(root)
      backup = definitions(scan, 'Tools#backup').fetch(0)
      module_copy = definitions(scan, 'Tools.work').fetch(0)

      expect(scan.call_sites).to include(
        have_attributes(caller_id: backup.graph_id, message: 'work'),
        have_attributes(caller_id: module_copy.graph_id, message: 'helper')
      )
      expect([backup, module_copy]).to all(satisfy { |node| node.graph_id.start_with?('def:v1:') })
    end
  end

  it 'copies calls from every reopened definition for an explicit module function' do
    files = {
      'lib/a.rb' => "module Tools\n  def work\n    from_a\n  end\nend\n",
      'lib/b.rb' => "module Tools\n  def work\n    from_b\n  end\nend\n",
      'lib/c.rb' => "module Tools\n  module_function :work\nend\n"
    }

    with_project(files: files) do |root|
      scan = scan_project(root)
      instances = definitions(scan, 'Tools#work')
      module_copy = definitions(scan, 'Tools.work').fetch(0)
      copied_calls = scan.call_sites.select { |site| site.caller_id == module_copy.graph_id }

      expect(copied_calls.map(&:message)).to contain_exactly('from_a', 'from_b')
      expect(instances.map(&:visibility)).to contain_exactly(:public, :public)
    end
  end

  it 'resolves an explicit module function declared before reopened definitions' do
    files = {
      'lib/a_macro.rb' => "module Tools\n  module_function :work\nend\n",
      'lib/b.rb' => "module Tools\n  def work\n    from_b\n  end\nend\n",
      'lib/c.rb' => "module Tools\n  def work\n    from_c\n  end\nend\n"
    }

    with_project(files: files) do |root|
      scan = scan_project(root)
      module_copy = definitions(scan, 'Tools.work').fetch(0)
      copied_calls = scan.call_sites.select { |site| site.caller_id == module_copy.graph_id }

      expect(copied_calls.map(&:message)).to contain_exactly('from_b', 'from_c')
    end
  end

  it 'keeps implicit module-function copies associated with their syntactic definitions' do
    files = {
      'lib/a.rb' => "module Tools\n  module_function\n  def work\n    from_a\n  end\nend\n",
      'lib/b.rb' => "module Tools\n  module_function\n  def work\n    from_b\n  end\nend\n"
    }

    with_project(files: files) do |root|
      scan = scan_project(root)
      copies = definitions(scan, 'Tools.work').to_h { |definition| [definition.file, definition] }

      expect(scan.call_sites.select { |site| site.caller_id == copies.fetch('lib/a.rb').graph_id }.map(&:message))
        .to contain_exactly('from_a')
      expect(scan.call_sites.select { |site| site.caller_id == copies.fetch('lib/b.rb').graph_id }.map(&:message))
        .to contain_exactly('from_b')
    end
  end

  it 'keeps definition ids stable across comments and line shifts' do
    original = "class Shifted\n  def call\n    helper\n  end\nend\n"
    shifted = "# leading comment\n\nclass Shifted\n  # method comment\n  def call\n    helper\n  end\nend\n"

    with_project(files: { 'lib/shifted.rb' => original }) do |root|
      first = definitions(scan_in_order(root, ['lib/shifted.rb']), 'Shifted#call').fetch(0)
      write_project_file(root, 'lib/shifted.rb', shifted)
      second = definitions(scan_in_order(root, ['lib/shifted.rb']), 'Shifted#call').fetch(0)

      expect(second.line).not_to eq(first.line)
      expect(second).to have_attributes(body_digest: first.body_digest, definition_id: first.definition_id)
    end
  end

  it 'is deterministic across input order and cache round trips' do
    files = {
      'lib/a.rb' => "class Ordered\n  def call\n    from_a\n  end\nend\n",
      'lib/b.rb' => "class Ordered\n  def call\n    from_b\n  end\nend\n"
    }

    with_project(files: files) do |root|
      forward = scan_in_order(root, files.keys)
      reverse = scan_in_order(root, files.keys.reverse)
      cached_first = scan_project(root)
      cached_second = project_for(root).scan_result

      expect(reverse.nodes.map(&:to_h)).to eq(forward.nodes.map(&:to_h))
      expect(reverse.call_sites.map(&:to_h)).to eq(forward.call_sites.map(&:to_h))
      expect(cached_second.nodes.map(&:to_h)).to eq(cached_first.nodes.map(&:to_h))
      expect(cached_second.call_sites.map(&:to_h)).to eq(cached_first.call_sites.map(&:to_h))
    end
  end
end
