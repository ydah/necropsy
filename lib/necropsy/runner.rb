# frozen_string_literal: true

module Necropsy
  class Runner
    attr_reader :root, :config, :analyzers

    def initialize(root:, config_path: nil, analyzers: nil)
      @root = File.expand_path(root)
      @config = Configuration.load(root: @root, path: config_path)
      @analyzers = analyzers
    end

    def analyze
      project = Project.new(root: root, config: config)
      graph = CallGraph.new(project.scan_result)

      apply_entry_points(graph, project)
      configured_analyzers.each do |analyzer|
        graph.add_profile(analyzer.profile)
        graph.apply_result(analyzer.analyze(graph, project))
      end

      reachability = Reachability::Engine.new(graph).call
      findings = Confidence::Scorer.new(graph: graph, reachability: reachability, project: project).findings
      Report.new(root: root, graph: graph, findings: findings)
    end

    private

    def apply_entry_points(graph, project)
      EntryPoints::Plain.new.apply(graph, project)
      EntryPoints::Rails.new.apply(graph, project)
      EntryPoints::Test.new.apply(graph, project)
      graph.entrypoint_hints.each { |entry| graph.add_entry_point(entry.node_id, entry.reason) }
    end

    def configured_analyzers
      return analyzers if analyzers

      static = config.static_analyzers.filter_map do |name|
        case name
        when 'name_resolution'
          Analyzers::Static::NameResolution.new
        when 'cha'
          Analyzers::Static::CHA.new
        when 'rta'
          Analyzers::Static::RTA.new
        end
      end

      dynamic = []
      coverage_config = config.dynamic_config(:coverage)
      dynamic << Analyzers::Dynamic::CoverageImporter.new(coverage_config) if coverage_config['source']
      coverband_config = config.dynamic_config(:coverband)
      dynamic << Analyzers::Dynamic::CoverbandImporter.new(coverband_config) if coverband_config['source']
      trace_point_config = config.dynamic_config(:trace_point)
      dynamic << Analyzers::Dynamic::TracePointImporter.new(trace_point_config) if trace_point_config['source']

      static + dynamic + custom_analyzers
    end

    def custom_analyzers
      config.custom_analyzers.map do |class_name|
        constantize(class_name).new
      rescue NameError => e
        raise Error, "Could not load custom analyzer #{class_name}: #{e.message}"
      end
    end

    def constantize(class_name)
      class_name.split('::').reduce(Object) { |constant, name| constant.const_get(name) }
    end
  end
end
