# frozen_string_literal: true

module Necropsy
  class AnalyzerExecution
    ANALYZER_ERROR_MESSAGE_BYTES = 500

    attr_reader :root, :config, :analyzers

    def initialize(root:, config:, analyzers: nil)
      @root = root
      @config = config
      @analyzers = analyzers
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

    def run(graph:, project:, configured_analyzer:, rta_pruning:)
      analyzer = analyzer_for_pruning(configured_analyzer, rta_pruning)
      profile = analyzer.profile
      raise TypeError, "#{analyzer.class} returned an invalid analyzer profile" unless profile.is_a?(AnalyzerProfile)

      graph.add_profile(profile)
      result = analyzer.analyze(graph, project)
      result = Analyzers::LegacyResultAdapter.new(graph: graph, profile: profile).adapt(result)
      validate_result_capabilities!(analyzer, result)
      graph.apply_result(result, refresh: false)
      [profile, result]
    rescue StandardError => e
      graph.add_blocker(analyzer_failure_blocker(analyzer || configured_analyzer, profile, e))
      [profile, nil]
    end

    private

    def analyzer_for_pruning(analyzer, mode)
      return analyzer unless analyzer.is_a?(Analyzers::Static::RTA)

      configured = analyzer.with_pruning(mode)
      return configured unless mode == :rank_only

      configured.without_redundant_edges
    end

    def analyzer_failure_blocker(analyzer, profile, error)
      analyzer_name = profile&.name&.to_s || analyzer.class.name
      error_message = safe_error_message(error)
      Blocker.new(
        kind: :analyzer_failure,
        scope_kind: :global,
        scope_value: '*',
        source: analyzer_name,
        reason: "Analyzer #{analyzer_name} failed: #{error.class}: #{error_message}",
        suggested_action: :fix_analyzer,
        metadata: {
          'analyzer' => analyzer_name,
          'analyzer_class' => analyzer.class.name,
          'caller_domain' => 'runtime',
          'error_class' => error.class.name,
          'error_message' => error_message
        }
      )
    end

    def validate_result_capabilities!(analyzer, result)
      complete = Array(result.resolutions).any? { |record| record.resolution.status == :complete }
      return unless complete
      return if Array(analyzer.capabilities).map(&:to_sym).include?(:complete_resolution)

      raise TypeError, "#{analyzer.class} emitted complete resolution without complete_resolution capability"
    end

    def safe_error_message(error)
      message = error.message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      return message if message.bytesize <= ANALYZER_ERROR_MESSAGE_BYTES

      "#{message.byteslice(0, ANALYZER_ERROR_MESSAGE_BYTES).to_s.scrub}\u2026"
    rescue StandardError, SystemStackError
      'unavailable'
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
