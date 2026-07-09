# frozen_string_literal: true

require 'set'

module GraphHelpers
  def node(id, kind: :instance_method, file: 'app/models/sample.rb', line: 1, end_line: line, owner: 'Sample',
           name: id.split(/[.#]/).last, test: false, defined_via: :def)
    Necropsy::Node.new(
      id: id,
      kind: kind,
      file: file,
      line: line,
      end_line: end_line,
      defined_via: defined_via,
      owner: owner,
      name: name,
      test: test
    )
  end

  def call_site(caller_id:, message:, receiver_kind: :implicit, receiver_name: nil, file: 'app/models/sample.rb',
                line: 1, test: false, dynamic: false, metadata: {})
    Necropsy::CallSite.new(
      caller_id: caller_id,
      message: message,
      receiver_kind: receiver_kind,
      receiver_name: receiver_name,
      file: file,
      line: line,
      test: test,
      dynamic: dynamic,
      metadata: metadata
    )
  end

  def class_info(id, kind: :class, superclass: nil, superclass_candidates: [], includes: [], prepends: [], extends: [],
                 dynamic: false, file: 'app/models/sample.rb', line: 1)
    Necropsy::ClassInfo.new(
      id: id,
      kind: kind,
      file: file,
      line: line,
      superclass: superclass,
      superclass_candidates: superclass_candidates,
      includes: includes,
      prepends: prepends,
      extends: extends,
      dynamic: dynamic
    )
  end

  def scan_result(nodes:, call_sites: [], instantiated_classes: Set.new, uncertainties: {}, class_infos: [],
                  entrypoint_hints: [])
    Necropsy::ScanResult.new(
      nodes: nodes,
      call_sites: call_sites,
      instantiated_classes: instantiated_classes,
      uncertainties: Hash.new { |hash, key| hash[key] = [] }.merge(uncertainties),
      class_infos: class_infos,
      entrypoint_hints: entrypoint_hints
    )
  end

  def graph_with(nodes:, call_sites: [], instantiated_classes: Set.new, uncertainties: {}, class_infos: [],
                 entrypoint_hints: [])
    Necropsy::CallGraph.new(
      scan_result(
        nodes: nodes,
        call_sites: call_sites,
        instantiated_classes: instantiated_classes,
        uncertainties: uncertainties,
        class_infos: class_infos,
        entrypoint_hints: entrypoint_hints
      )
    )
  end

  def evidence(analyzer: :spec, kind: :call_edge, weight: 1.0, details: 'spec evidence', metadata: {})
    Necropsy::Evidence.new(
      analyzer: analyzer,
      kind: kind,
      weight: weight,
      details: details,
      metadata: metadata
    )
  end

  def analyzer_result(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {})
    Necropsy::AnalyzerResult.new(
      edge_evidences: edge_evidences,
      alive_evidences: alive_evidences,
      uncertainties: Hash.new { |hash, key| hash[key] = [] }.merge(uncertainties),
      observation: observation
    )
  end

  def finding(id: 'Sample#dead', classification: :unreachable, confidence: :high, score: 0.8, file: 'sample.rb',
              line: 1)
    Necropsy::Finding.new(
      node: node(id, file: file, line: line),
      classification: classification,
      confidence: confidence,
      score: score,
      reasons: ['spec reason'],
      evidences: [evidence]
    )
  end

  def report_with_findings(findings, graph: nil, root: '/tmp/project')
    graph ||= graph_with(nodes: findings.map(&:node))
    Necropsy::Report.new(root: root, graph: graph, findings: findings)
  end
end

RSpec.configure do |config|
  config.include GraphHelpers
end
