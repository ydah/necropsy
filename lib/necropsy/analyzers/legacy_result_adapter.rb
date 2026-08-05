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

        @edges_by_call_site_id = mapped_edges(result.edge_evidences)
        result.with(
          resolutions: graph.call_sites.map { |site| resolution_for(site) },
          evidences: EvidenceCollection.collect(result.evidences, result.edge_evidences, result.alive_evidences)
        )
      end

      private

      attr_reader :graph, :profile

      def legacy_static_result?(result)
        profile.kind.to_sym == :static && result.resolutions.nil?
      end

      def mapped_edges(edges)
        edges.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |edge, mapped|
          site = matching_call_site(edge)
          mapped[site.call_site_id] << edge if site
        end
      end

      def matching_call_site(edge)
        metadata = edge.evidence.metadata
        call_site_id = value(metadata, :call_site_id)
        return unique_site { |site| site.call_site_id == call_site_id.to_s } unless call_site_id.equal?(MISSING)

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
          producer_version: profile.version,
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
