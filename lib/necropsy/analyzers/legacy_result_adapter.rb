# frozen_string_literal: true

module Necropsy
  module Analyzers
    class LegacyResultAdapter
      MISSING = Object.new.freeze
      private_constant :MISSING

      def initialize(graph:, profile:)
        @graph = graph
        @profile = profile
      end

      def adapt(result)
        return result unless legacy_static_result?(result)

        edge_evidences = normalize_edge_evidences(result.edge_evidences)
        alive_evidences = normalize_alive_evidences(result.alive_evidences)
        wrapped_evidences = {}.compare_by_identity
        result.edge_evidences.each { |edge| wrapped_evidences[edge.evidence] = true }
        result.alive_evidences.each { |alive| wrapped_evidences[alive.evidence] = true }
        evidences = result.evidences.reject { |record| wrapped_evidences.key?(record) }.map do |record|
          normalize_evidence(
            record,
            relation: record.kind,
            source: { 'type' => 'legacy_adapter', 'producer' => profile.name.to_s },
            scope: {}
          )
        end
        result.with(
          edge_evidences: edge_evidences,
          alive_evidences: alive_evidences,
          resolutions: graph.call_sites.map { |site| resolution_for(site) },
          evidences: EvidenceCollection.collect(evidences, edge_evidences, alive_evidences)
        )
      end

      private

      attr_reader :graph, :profile

      def legacy_static_result?(result)
        profile.kind.to_sym == :static && result.resolutions.nil?
      end

      def normalize_edge_evidences(edges)
        @edges_by_call_site_id = Hash.new { |hash, key| hash[key] = [] }
        edges.map do |edge|
          site = matching_call_site(edge)
          normalized = EdgeEvidence.new(
            caller_id: edge.caller_id,
            callee_id: edge.callee_id,
            evidence: normalize_evidence(
              edge.evidence,
              relation: :call_edge,
              source: legacy_edge_source(edge, site),
              scope: legacy_edge_scope(edge, site)
            )
          )
          @edges_by_call_site_id[site.call_site_id] << normalized if site
          normalized
        end
      end

      def normalize_alive_evidences(alive_evidences)
        alive_evidences.map do |alive|
          AliveEvidence.new(
            node_id: alive.node_id,
            evidence: normalize_evidence(
              alive.evidence,
              relation: :alive,
              source: { 'type' => 'legacy_adapter', 'producer' => profile.name.to_s },
              scope: { 'node_reference' => alive.node_id.to_s }
            )
          )
        end
      end

      def normalize_evidence(record, relation:, source:, scope:)
        normalized = if record.grade
                       record
                     else
                       Evidence.new(
                         analyzer: record.analyzer,
                         kind: record.kind,
                         weight: record.weight,
                         details: record.details,
                         metadata: record.metadata,
                         producer: profile.name,
                         producer_version: profile.version || 'unversioned',
                         grade: legacy_evidence_grade,
                         relation: relation,
                         source: source,
                         assumptions: profile.assumptions,
                         scope: scope
                       )
                     end
        return normalized if normalized.evidence_id

        normalized.with(
          evidence_id: EvidenceIdentity.generate(normalized.to_h.except('evidence_id'))
        )
      end

      def legacy_evidence_grade
        profile.soundness.to_sym == :conservative ? :conservative : :heuristic
      end

      def legacy_edge_source(edge, site)
        {
          'type' => 'legacy_adapter',
          'producer' => profile.name.to_s,
          'file' => site&.file,
          'line' => site&.line,
          'caller_reference' => edge.caller_id.to_s,
          'callee_reference' => edge.callee_id.to_s
        }.compact
      end

      def legacy_edge_scope(edge, site)
        if site
          return {
            'call_site_id' => site.call_site_id,
            'caller_definition_id' => site.caller_id,
            'target_reference' => edge.callee_id.to_s
          }
        end

        { 'caller_reference' => edge.caller_id.to_s, 'target_reference' => edge.callee_id.to_s }
      end

      def matching_call_site(edge)
        metadata = edge.evidence.metadata
        call_site_id = value(metadata, :call_site_id)
        unless call_site_id.equal?(MISSING)
          caller_id = physical_definition_id(edge.caller_id)
          return unless caller_id

          return unique_site do |site|
            site.call_site_id == call_site_id.to_s && site.caller_id == caller_id
          end
        end

        matching_legacy_call_site(edge, metadata)
      end

      def matching_legacy_call_site(edge, metadata)
        caller_id = physical_definition_id(edge.caller_id)
        return unless caller_id

        metadata_caller = value(metadata, :caller_definition_id, :caller_id)
        return if metadata_caller.equal?(MISSING)
        return unless physical_definition_id(metadata_caller) == caller_id

        signature = legacy_signature(metadata, caller_id)
        return unless signature

        unique_site do |site|
          site.caller_id == caller_id && legacy_signature(site.to_h, caller_id) == signature
        end
      end

      def legacy_signature(attributes, caller_id)
        message = value(attributes, :message)
        receiver_kind = value(attributes, :receiver_kind)
        receiver_name = value(attributes, :receiver_name)
        file = value(attributes, :file)
        line = value(attributes, :line)
        test = value(attributes, :test)
        dynamic = value(attributes, :dynamic)
        metadata = value(attributes, :metadata)
        values = [message, receiver_kind, receiver_name, file, line, test, dynamic, metadata]
        return if values.any? { |item| item.equal?(MISSING) }

        CallSiteIdentity.legacy_id(
          caller_definition_id: caller_id,
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

      def unique_site(&)
        matches = graph.call_sites.select(&)
        matches.first if matches.one?
      end

      def physical_definition_id(reference)
        graph.nodes.lookup(reference.to_s).node&.graph_id
      end

      def resolution_for(site)
        edges = @edges_by_call_site_id.fetch(site.call_site_id, [])
        targets = edges.filter_map { |edge| physical_definition_id(edge.callee_id) }.uniq.sort
        status = targets.empty? ? :unknown : :partial
        ResolutionRecord.new(
          resolution: Resolution.new(
            call_site_id: site.call_site_id,
            target_definition_ids: targets,
            status: status,
            unknown_scope: UnknownScope.new(scope_kind: :message, scope_value: site.message, match: :exact),
            evidence_ids: edges.filter_map { |edge| edge.evidence.evidence_id }.uniq.sort
          ),
          producer: profile.name,
          producer_version: profile.version || 'unversioned',
          assumptions: profile.assumptions
        )
      end

      def value(attributes, *keys)
        return MISSING unless attributes.respond_to?(:key?)

        keys.each do |key|
          return attributes[key.to_s] if attributes.key?(key.to_s)
          return attributes[key] if attributes.key?(key)
        end
        MISSING
      end
    end
  end
end
