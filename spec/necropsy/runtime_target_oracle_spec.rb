# frozen_string_literal: true

RSpec.describe 'generated runtime target oracle' do
  def oracle_cases
    %i[inherited included prepended overridden extended]
  end

  def oracle_source
    oracle_cases.each_with_index.map do |kind, index|
      mix = "OracleMix#{index}"
      base = "OracleBase#{index}"
      child = "OracleChild#{index}"
      runner = "OracleRunner#{index}"
      relation = case kind
                 when :included then "include #{mix}"
                 when :prepended then "prepend #{mix}"
                 when :extended then "extend #{mix}"
                 when :overridden then 'def work = :child'
                 else ''
                 end
      receiver = kind == :extended ? child : "#{child}.new"
      <<~RUBY
        module #{mix}
          def work = :module
        end
        class #{base}
          def work = :base
        end
        class #{child} < #{base}
          #{relation}
        end
        class #{runner}
          def self.call = #{receiver}.work
        end
        #{runner}.call
      RUBY
    end.join("\n")
  end

  it 'contains every runtime-observed generated dispatch target in the static graph' do
    with_project(files: { 'bin/oracle.rb' => oracle_source }, config: { cache: { enabled: false } }) do |root|
      report = Necropsy::Runner.new(root: root).analyze
      output = File.join(root, 'runtime.yml')
      Necropsy::Analyzers::Dynamic::TracePointCollector.record(root: root, output: output) do
        load File.join(root, 'bin/oracle.rb')
      end
      runtime_edges = YAML.load_file(output).fetch('edges')

      oracle_cases.each_index do |index|
        runner_id = "OracleRunner#{index}.call"
        observed = runtime_edges.find { |edge| edge['caller_id'] == runner_id && edge['callee_id'].end_with?('#work') }
        expect(observed).not_to be_nil

        runner = report.graph.method_nodes.find { |node| node.symbol_id == runner_id }
        static_symbols = report.graph.edges_from(runner.graph_id).keys.filter_map do |target_id|
          report.graph.nodes[target_id]&.symbol_id
        end
        expect(static_symbols).to include(observed.fetch('callee_id'))
      end
    end
  end
end
