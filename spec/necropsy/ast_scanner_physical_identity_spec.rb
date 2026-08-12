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
      expect(scan.call_sites.select { |site| %w[first_target second_target].include?(site.message) }
                            .map(&:call_site_id).uniq.length).to eq(2)
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

  it 'distinguishes identical calls on the same source line' do
    source = 'class SameLine; def run; helper; helper; end; end'

    with_project(files: { 'lib/same_line.rb' => source }) do |root|
      sites = scan_project(root).call_sites.select { |site| site.message == 'helper' }

      expect(sites.length).to eq(2)
      expect(sites.map(&:line).uniq).to contain_exactly(1)
      expect(sites.map(&:caller_definition_id).uniq.length).to eq(1)
      expect(sites.map(&:call_site_id).uniq.length).to eq(2)
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
      instance = definitions(scan, 'Tools#work').fetch(0)
      module_copy = definitions(scan, 'Tools.work').fetch(0)
      instance_site = scan.call_sites.find { |site| site.caller_id == instance.graph_id && site.message == 'helper' }
      copied_site = scan.call_sites.find { |site| site.caller_id == module_copy.graph_id && site.message == 'helper' }

      expect(scan.call_sites).to include(
        have_attributes(caller_id: backup.graph_id, message: 'work'),
        have_attributes(caller_id: module_copy.graph_id, message: 'helper')
      )
      expect([backup, module_copy]).to all(satisfy { |node| node.graph_id.start_with?('def:v1:') })
      expect(copied_site.call_site_id).not_to eq(instance_site.call_site_id)
      expect(copied_site.call_site_id).to eq(
        Necropsy::CallSiteIdentity.derived_id(
          parent_call_site_id: instance_site.call_site_id,
          derivation: :module_function,
          caller_definition_id: module_copy.graph_id,
          message: instance_site.message
        )
      )
      expect(copied_site.metadata).to include(
        'derived_from_call_site_id' => instance_site.call_site_id,
        'derived_via' => 'module_function'
      )
    end
  end

  it 'binds an unconditional same-file alias to the physical implementation active at that point' do
    source = <<~RUBY
      class AliasedImplementation
        def work
          old_body
        end
        alias backup work
        def work
          new_body
        end
      end
    RUBY

    with_project(files: { 'lib/aliased_implementation.rb' => source }) do |root|
      scan = scan_project(root)
      graph = graph_for_scan(scan)
      works = definitions(scan, 'AliasedImplementation#work')
      backup = definitions(scan, 'AliasedImplementation#backup').fetch(0)
      alias_site = scan.call_sites.find { |site| site.caller_id == backup.graph_id && site.message == 'work' }

      expect(alias_site.metadata.fetch('physical_target_definition_id')).to eq(works.first.graph_id)
      expect(graph.method_lookup(alias_site)).to have_attributes(
        status: :complete,
        targets: [works.first],
        reason: 'physical_definition_relation'
      )
    end
  end

  it 'keeps cross-file visibility changes conservative when load order is unknown' do
    files = {
      'lib/a_modifier.rb' => "class VisibilityOrder\n  private :work\nend\n",
      'lib/z_definition.rb' => "class VisibilityOrder\n  def work; end\nend\n"
    }

    with_project(files: files) do |root|
      scan = scan_project(root)
      work = definitions(scan, 'VisibilityOrder#work').fetch(0)

      expect(work.visibility).to eq(:public)
      expect(scan.semantic_blockers).to include(
        have_attributes(kind: :visibility_activation, scope_kind: :message, scope_value: 'work')
      )
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
      first_scan = scan_in_order(root, ['lib/shifted.rb'])
      first = definitions(first_scan, 'Shifted#call').fetch(0)
      first_site = first_scan.call_sites.find { |site| site.message == 'helper' }
      write_project_file(root, 'lib/shifted.rb', shifted)
      second_scan = scan_in_order(root, ['lib/shifted.rb'])
      second = definitions(second_scan, 'Shifted#call').fetch(0)
      second_site = second_scan.call_sites.find { |site| site.message == 'helper' }

      expect(second.line).not_to eq(first.line)
      expect(second).to have_attributes(body_digest: first.body_digest, definition_id: first.definition_id)
      expect(second_site.line).not_to eq(first_site.line)
      expect(second_site).to have_attributes(
        call_site_id: first_site.call_site_id,
        caller_definition_id: first_site.caller_definition_id
      )
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
      expect(forward.call_sites).to all(satisfy { |site| site.call_site_id.start_with?('call:v1:') })
      expect(cached_second.nodes.map(&:to_h)).to eq(cached_first.nodes.map(&:to_h))
      expect(cached_second.call_sites.map(&:to_h)).to eq(cached_first.call_sites.map(&:to_h))
    end
  end
end
