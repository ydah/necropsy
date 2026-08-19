# frozen_string_literal: true

module Necropsy
  Node = Data.define(
    :id,
    :symbol_id,
    :definition_id,
    :body_digest,
    :ordinal,
    :kind,
    :file,
    :line,
    :end_line,
    :defined_via,
    :owner,
    :name,
    :test,
    :visibility
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 10 && attributes.empty?

        id, kind, file, line, end_line, defined_via, owner, name, test, visibility = values
        data_new(
          id: id, kind: kind, file: file, line: line, end_line: end_line, defined_via: defined_via,
          owner: owner, name: name, test: test, visibility: visibility
        )
      end

      private :data_new, :compatible_new
    end

    def initialize(id:, kind:, file:, line:, end_line:, defined_via:, owner:, name:, test:, visibility:,
                   symbol_id: id, definition_id: id, body_digest: nil, ordinal: 0)
      super
    end

    def method?
      kind != :block_entry
    end

    def graph_id
      definition_id
    end

    def fingerprint(classification)
      Digest::SHA256.hexdigest("#{classification}:#{symbol_id}")
    end

    alias_method :logical_fingerprint, :fingerprint

    def physical_fingerprint(classification)
      Digest::SHA256.hexdigest("#{classification}:#{definition_id}")
    end

    def to_h
      {
        'id' => id,
        'symbol_id' => symbol_id,
        'definition_id' => definition_id,
        'body_digest' => body_digest,
        'ordinal' => ordinal,
        'kind' => kind.to_s,
        'file' => file,
        'line' => line,
        'end_line' => end_line,
        'defined_via' => defined_via.to_s,
        'owner' => owner,
        'name' => name,
        'test' => test,
        'visibility' => visibility.to_s
      }
    end
  end

  MethodLookup = Data.define(
    :targets,
    :status,
    :rejected_targets,
    :lookup_chain,
    :reason
  ) do
    def initialize(targets:, status:, rejected_targets: [], lookup_chain: [], reason: nil)
      status = status.to_sym
      raise ArgumentError, "invalid method lookup status: #{status.inspect}" unless RESOLUTION_STATUSES.include?(status)

      targets = Array(targets).uniq(&:graph_id).sort_by(&:graph_id).freeze
      rejected_targets = Array(rejected_targets).uniq.sort_by do |target|
        [target.definition_id, target.reason, target.evidence_ids]
      end.freeze
      lookup_chain = Array(lookup_chain).map(&:to_s).freeze
      super
    end

    def complete?
      status == :complete
    end

    def partial?
      status == :partial
    end

    def unknown?
      status == :unknown
    end

    def to_h
      {
        'target_definition_ids' => targets.map(&:graph_id),
        'status' => status.to_s,
        'rejected_targets' => rejected_targets.map(&:to_h),
        'lookup_chain' => lookup_chain,
        'reason' => reason
      }
    end
  end

  Edge = Data.define(:caller_id, :callee_id, :evidences) do
    def to_h
      {
        'caller_id' => caller_id,
        'callee_id' => callee_id,
        'evidence_ids' => evidences.filter_map(&:evidence_id).sort,
        'evidences' => evidences.map(&:to_h)
      }
    end
  end

  EdgeRelation = Data.define(:caller_id, :callee_id, :evidence_ids, :projection) do
    def to_h
      {
        'caller_id' => caller_id,
        'callee_id' => callee_id,
        'evidence_ids' => evidence_ids,
        'projection' => projection.to_s
      }
    end
  end

  Root = Data.define(:definition_id, :domain, :reason, :evidence) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        return data_new(node_id: values[0], reason: values[1]) if values.length == 2 && attributes.empty?

        data_new(*values, **attributes)
      end
      alias_method :[], :new

      private :data_new
    end

    def initialize(reason:, definition_id: nil, node_id: nil, domain: nil, evidence: nil)
      definition_id ||= node_id
      definition_id = ModelNormalization.identifier(definition_id, 'definition_id')
      reason = ModelNormalization.identifier(reason, 'reason').to_sym
      domain ||= reason == :test_suite ? :test : :runtime
      domain = domain.to_sym if domain.respond_to?(:to_sym)
      raise ArgumentError, "invalid root domain: #{domain.inspect}" unless ROOT_DOMAINS.include?(domain)

      evidence ||= { 'type' => 'entry_point', 'reason' => reason.to_s }
      evidence = evidence.to_h if evidence.respond_to?(:to_h)
      raise ArgumentError, 'root evidence must be a Hash' unless evidence.is_a?(Hash)

      super(definition_id: definition_id, domain: domain, reason: reason, evidence: evidence.freeze)
    end

    alias_method :node_id, :definition_id

    def test?
      domain == :test
    end

    def runtime?
      domain == :runtime
    end

    def external?
      domain == :external
    end

    def to_h
      {
        'node_id' => node_id,
        'definition_id' => definition_id,
        'domain' => domain.to_s,
        'reason' => reason.to_s,
        'evidence' => evidence
      }
    end
  end
  EntryPoint = Root

  ClassInfo = Data.define(
    :id,
    :kind,
    :file,
    :line,
    :superclass,
    :superclass_candidates,
    :includes,
    :prepends,
    :extends,
    :singleton_includes,
    :singleton_prepends,
    :dynamic
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 10 && attributes.empty?

        id, kind, file, line, superclass, superclass_candidates, includes, prepends, extends, dynamic = values
        data_new(
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
      alias_method :[], :new

      private :data_new
    end

    def initialize(id:, kind:, file:, line:, superclass:, superclass_candidates:, includes:, prepends:, extends:,
                   dynamic:, singleton_includes: [], singleton_prepends: [])
      singleton_includes = extends if singleton_includes.empty? && !extends.empty?
      super
    end

    def to_h
      {
        'id' => id,
        'kind' => kind.to_s,
        'file' => file,
        'line' => line,
        'superclass' => superclass,
        'superclass_candidates' => superclass_candidates,
        'includes' => includes,
        'prepends' => prepends,
        'extends' => extends,
        'singleton_includes' => singleton_includes,
        'singleton_prepends' => singleton_prepends,
        'dynamic' => dynamic
      }
    end
  end

  CallSite = Data.define(
    :call_site_id,
    :caller_id,
    :message,
    :receiver_kind,
    :receiver_name,
    :file,
    :line,
    :test,
    :dynamic,
    :metadata
  ) do
    class << self
      alias_method :data_new, :new

      def new(*values, **attributes)
        compatible_new(*values, **attributes)
      end
      alias_method :[], :new

      private

      def compatible_new(*values, **attributes)
        return data_new(*values, **attributes) unless values.length == 9 && attributes.empty?

        caller_id, message, receiver_kind, receiver_name, file, line, test, dynamic, metadata = values
        data_new(
          caller_id: caller_id, message: message, receiver_kind: receiver_kind, receiver_name: receiver_name,
          file: file, line: line, test: test, dynamic: dynamic, metadata: metadata
        )
      end

      private :data_new, :compatible_new
    end

    def initialize(caller_id:, message:, receiver_kind:, receiver_name:, file:, line:, test:, dynamic:, metadata:,
                   call_site_id: nil)
      call_site_id ||= CallSiteIdentity.legacy_id(
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
      super
    end

    alias_method :caller_definition_id, :caller_id

    def to_h
      {
        'call_site_id' => call_site_id,
        'caller_id' => caller_id,
        'caller_definition_id' => caller_definition_id,
        'message' => message,
        'receiver_kind' => receiver_kind.to_s,
        'receiver_name' => receiver_name,
        'file' => file,
        'line' => line,
        'test' => test,
        'dynamic' => dynamic,
        'metadata' => metadata
      }
    end
  end
end
