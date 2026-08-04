# frozen_string_literal: true

require 'json'

module Necropsy
  class Diagnostics
    FORMATS = %i[human json].freeze

    def initialize(report)
      raise Error, 'Reachability witnesses are unavailable for this report' unless report.reachability

      @report = report
    end

    def why(node_id)
      node = graph.nodes[node_id]
      return missing_payload(node_id) unless node

      runtime_path = reachability.witness(node_id)
      return alive_payload(node, runtime_path, :runtime) if runtime_path

      finding = finding_for(node_id)
      return dead_payload(node, finding) if finding&.classification == :blocked

      test_path = reachability.witness(node_id, kind: :test)
      return alive_payload(node, test_path, :test) if test_path

      dead_payload(node, finding)
    end

    def explain(node_id)
      node = graph.nodes[node_id]
      return missing_payload(node_id) unless node

      finding = finding_for(node_id)
      return { 'status' => 'alive', 'node' => node.to_h } unless finding

      {
        'status' => 'finding',
        'node' => node.to_h,
        'classification' => finding.classification.to_s,
        'confidence' => finding.confidence.to_s,
        'score' => finding.score,
        'components' => finding.score_components.map(&:to_h),
        'reasons' => finding.reasons,
        'blockers' => finding.blockers.map(&:to_h)
      }
    end

    def render(payload, format: :human)
      normalized = format.to_sym
      raise Error, "Diagnostics support only human or json output, not #{format}" unless FORMATS.include?(normalized)

      return JSON.pretty_generate(payload) if normalized == :json

      render_human(payload)
    end

    private

    attr_reader :report

    def graph
      report.graph
    end

    def reachability
      report.reachability
    end

    def alive_payload(node, path, kind)
      {
        'status' => 'alive',
        'kind' => kind.to_s,
        'node' => node.to_h,
        'path' => path.each_with_index.map do |node_id, index|
          caller_id = index.positive? ? path[index - 1] : nil
          path_step(node_id, caller_id)
        end
      }
    end

    def path_step(node_id, caller_id)
      step = { 'node' => graph.nodes.fetch(node_id).to_h }
      entry = graph.entry_points.find { |candidate| candidate.node_id == node_id }
      step['entry_reason'] = entry.reason.to_s if entry
      return step unless caller_id

      evidences = graph.edges_from(caller_id).fetch(node_id, [])
      step['edge'] = {
        'caller_id' => caller_id,
        'callee_id' => node_id,
        'evidences' => evidences.map(&:to_h)
      }
      step
    end

    def dead_payload(node, finding = finding_for(node.id))
      blockers = finding ? finding.blockers : graph.matching_blockers(node)
      {
        'status' => finding&.classification == :blocked ? 'blocked' : 'dead',
        'node' => node.to_h,
        'classification' => finding&.classification&.to_s,
        'nearest_alive' => nearest_alive(node.id),
        'uncertainties' => graph.uncertainties(node.id),
        'blockers' => blockers.map(&:to_h)
      }
    end

    def finding_for(node_id)
      report.findings.find { |candidate| candidate.node.id == node_id }
    end

    def nearest_alive(node_id)
      kinds = reachability.runtime_alive.to_h { |id| [id, 'runtime'] }
      reachability.test_alive.each { |id| kinds[id] ||= 'test' }
      visited = { node_id => 0 }
      queue = [node_id]

      until queue.empty?
        current = queue.shift
        neighbors(current).each do |neighbor|
          next if visited.key?(neighbor)

          distance = visited.fetch(current) + 1
          return { 'node_id' => neighbor, 'kind' => kinds.fetch(neighbor), 'distance' => distance } if kinds.key?(neighbor)

          visited[neighbor] = distance
          queue << neighbor
        end
      end
      nil
    end

    def neighbors(node_id)
      outgoing = graph.edges_from(node_id).keys
      incoming = graph.incoming_edges(node_id).map(&:caller_id)
      (outgoing + incoming).uniq.sort
    end

    def missing_payload(node_id)
      terms = [node_id, node_id.split(/[.#]/).last].compact.map(&:downcase).reject { |term| term.length < 2 }
      suggestions = graph.nodes.keys.select do |candidate|
        terms.any? { |term| candidate.downcase[term] }
      end.sort.first(10)
      { 'status' => 'not_found', 'node_id' => node_id, 'suggestions' => suggestions }
    end

    def render_human(payload)
      case payload.fetch('status')
      when 'alive' then render_alive(payload)
      when 'dead', 'blocked' then render_dead(payload)
      when 'finding' then render_explanation(payload)
      when 'not_found' then render_missing(payload)
      else "#{payload.dig('node', 'id')} is alive and has no dead-code finding."
      end
    end

    def render_alive(payload)
      lines = ["Alive (#{payload.fetch('kind')}): #{payload.dig('node', 'id')}"]
      payload.fetch('path').each_with_index do |step, index|
        suffix = step['entry_reason'] ? " entry=#{step['entry_reason']}" : ''
        lines << "  #{index}. #{step.dig('node', 'id')}#{suffix}"
        Array(step.dig('edge', 'evidences')).each { |evidence| lines << render_evidence(evidence) }
      end
      lines.join("\n")
    end

    def render_evidence(evidence)
      metadata = evidence.fetch('metadata', {})
      location = [metadata['file'], metadata['line']].compact.join(':')
      suffix = location.empty? ? '' : " at #{location}"
      "     via #{evidence['analyzer']} weight=#{evidence['weight']}#{suffix}: #{evidence['details']}"
    end

    def render_dead(payload)
      lines = ["Dead: #{payload.dig('node', 'id')}"]
      lines << "Classification: #{payload['classification']}" if payload['classification']
      nearest = payload['nearest_alive']
      lines << if nearest
                 "Nearest alive: #{nearest['node_id']} (#{nearest['kind']}, distance #{nearest['distance']})"
               else
                 'Nearest alive: none'
               end
      lines << 'Uncertainties: none' if payload.fetch('uncertainties').empty?
      payload.fetch('uncertainties').each { |message| lines << "Uncertainty: #{message}" }
      append_blockers(lines, payload.fetch('blockers', []))
      lines.join("\n")
    end

    def render_explanation(payload)
      lines = [
        "#{payload.dig('node', 'id')}: #{payload['classification']}",
        "Confidence: #{payload['confidence']} (score #{format('%.2f', payload['score'])})"
      ]
      payload.fetch('components').each do |component|
        lines << format(
          '  %<name>-28s %<value>+0.2f  %<details>s',
          name: component['name'], value: component['value'], details: component['details']
        )
      end
      lines << format('  %<name>-28s  %<value>0.2f', name: 'total', value: payload['score'])
      append_blockers(lines, payload.fetch('blockers', []))
      lines.join("\n")
    end

    def append_blockers(lines, blockers)
      blockers.each do |blocker|
        metadata = blocker.fetch('metadata', {})
        location = [metadata['file'], metadata['line']].compact.join(':')
        caller = metadata['caller_id'] ? " caller=#{metadata['caller_id']}" : ''
        lines << "Blocker: #{blocker['kind']} at #{location}#{caller}"
        lines << "  Scope: #{blocker['scope_kind']}=#{blocker['scope_value'].inspect} message=#{metadata['message']}"
        lines << "  Reason: #{blocker['reason']}"
      end
    end

    def render_missing(payload)
      lines = ["Node not found: #{payload['node_id']}"]
      lines << "Suggestions: #{payload['suggestions'].join(', ')}" unless payload['suggestions'].empty?
      lines.join("\n")
    end
  end
end
