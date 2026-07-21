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
      rta_results = []

      apply_entry_points(graph, project)
      configured_analyzers.each do |analyzer|
        graph.add_profile(analyzer.profile)
        result = analyzer.analyze(graph, project)
        graph.apply_result(result)
        rta_results << result if analyzer.profile.name == :rta
      end
      rta_results.each { |result| graph.reconcile_rta_result(result) }

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
        else
          raise Error, "Unknown static analyzer: #{name}"
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
      config.custom_analyzers.map do |entry|
        class_name, required_path = custom_analyzer_definition(entry)
        require_custom_analyzer(required_path) if required_path
        constantize(class_name).new
      rescue NameError => e
        raise Error, "Could not load custom analyzer #{class_name}: #{e.message}"
      rescue LoadError => e
        raise Error, "Could not require custom analyzer #{class_name}: #{e.message}"
      end
    end

    def custom_analyzer_definition(entry)
      return [entry, nil] unless entry.is_a?(Hash)

      [entry.fetch('class'), entry['require']]
    end

    def require_custom_analyzer(path)
      expanded = File.expand_path(path, root)
      expanded = "#{expanded}.rb" if !File.file?(expanded) && File.file?("#{expanded}.rb")
      File.file?(expanded) ? require(expanded) : require(path)
    end

    def constantize(class_name)
      class_name.split('::').reduce(Object) { |constant, name| constant.const_get(name) }
    end
  end
end
