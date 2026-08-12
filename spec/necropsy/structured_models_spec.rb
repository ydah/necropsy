# frozen_string_literal: true

RSpec.describe 'structured analysis models' do
  let(:scope) do
    Necropsy::UnknownScope.new(scope_kind: :message, scope_value: 'call*', match: :glob)
  end

  describe Necropsy::UnknownScope do
    it 'normalizes scope values deterministically and round-trips hashes' do
      model = described_class.new(
        scope_kind: 'owner', scope_value: %w[Shipping Billing Shipping], match: 'exact'
      )

      expect(model).to have_attributes(
        scope_kind: :owner, scope_value: %w[Billing Shipping], match: :exact
      )
      expect(model.scope_value).to be_frozen
      expect(described_class.from_h(model.to_h)).to eq(model)
      expect(described_class.from_h(scope_kind: :owner, scope_value: %i[Shipping Billing], match: :exact)).to eq(model)
    end

    it 'rejects invalid kinds, match policies, and empty values' do
      expect do
        described_class.new(scope_kind: :receiver, scope_value: 'call', match: :exact)
      end.to raise_error(ArgumentError, /scope kind/)
      expect do
        described_class.new(scope_kind: :message, scope_value: 'call', match: :regexp)
      end.to raise_error(ArgumentError, /scope match/)
      expect do
        described_class.new(scope_kind: :message, scope_value: [], match: :exact)
      end.to raise_error(ArgumentError, /scope_value/)
    end
  end

  describe Necropsy::RejectedTarget do
    it 'normalizes evidence IDs and round-trips hashes' do
      model = described_class.new(
        definition_id: :'def:v1:target', reason: :private_visibility,
        evidence_ids: %w[evidence:z evidence:a evidence:z]
      )

      expect(model).to have_attributes(
        definition_id: 'def:v1:target', reason: 'private_visibility',
        evidence_ids: %w[evidence:a evidence:z]
      )
      expect(described_class.from_h(model.to_h)).to eq(model)
    end

    it 'rejects empty definition IDs and reasons' do
      expect do
        described_class.new(definition_id: '', reason: 'not callable')
      end.to raise_error(ArgumentError, /definition_id/)
      expect do
        described_class.new(definition_id: 'def:v1:target', reason: '')
      end.to raise_error(ArgumentError, /reason/)
    end
  end

  describe Necropsy::Resolution do
    it 'represents a complete empty target set without an unknown scope' do
      resolution = described_class.new(
        call_site_id: 'call:v1:none', target_definition_ids: [], status: :complete
      )

      expect(resolution).to have_attributes(
        status: :complete, target_definition_ids: [], unknown_scope: nil
      )
      expect(described_class.from_h(resolution.to_h)).to eq(resolution)
    end

    it 'normalizes a partial resolution with targets, scope, rejections, and evidence' do
      rejected_b = {
        'definition_id' => 'def:v1:b', 'reason' => 'arity mismatch',
        'evidence_ids' => %w[evidence:2 evidence:1]
      }
      rejected_a = Necropsy::RejectedTarget.new(definition_id: 'def:v1:a', reason: 'private')
      resolution = described_class.new(
        call_site_id: :'call:v1:partial',
        target_definition_ids: %w[def:v1:z def:v1:a def:v1:z],
        status: 'partial',
        unknown_scope: scope.to_h,
        rejected_targets: [rejected_b, rejected_a],
        evidence_ids: %w[evidence:z evidence:a evidence:z]
      )

      expect(resolution).to have_attributes(
        call_site_id: 'call:v1:partial',
        target_definition_ids: %w[def:v1:a def:v1:z],
        status: :partial,
        unknown_scope: scope,
        evidence_ids: %w[evidence:a evidence:z]
      )
      expect(resolution.rejected_targets.map(&:definition_id)).to eq(%w[def:v1:a def:v1:b])
      expect(described_class.from_h(resolution.to_h)).to eq(resolution)
    end

    it 'represents an unknown patterned scope without usable targets' do
      resolution = described_class.new(
        call_site_id: 'call:v1:unknown', target_definition_ids: [], status: :unknown,
        unknown_scope: { scope_kind: :namespace, scope_value: 'Billing::*', match: :glob }
      )

      expect(resolution).to have_attributes(status: :unknown, target_definition_ids: [])
      expect(resolution.unknown_scope).to have_attributes(
        scope_kind: :namespace, scope_value: 'Billing::*', match: :glob
      )
    end

    it 'rejects every invalid status and target/scope combination' do
      invalid = [
        { status: :complete, targets: [], scope: scope },
        { status: :partial, targets: [], scope: scope },
        { status: :partial, targets: ['def:v1:a'], scope: nil },
        { status: :unknown, targets: ['def:v1:a'], scope: scope },
        { status: :unknown, targets: [], scope: nil },
        { status: :maybe, targets: [], scope: nil }
      ]

      invalid.each do |attributes|
        expect do
          described_class.new(
            call_site_id: 'call:v1:invalid',
            target_definition_ids: attributes.fetch(:targets),
            status: attributes.fetch(:status),
            unknown_scope: attributes.fetch(:scope)
          )
        end.to raise_error(ArgumentError), attributes.inspect
      end
    end

    it 'is deterministic across input ordering and duplicate values' do
      attributes = {
        call_site_id: 'call:v1:stable', status: :partial, unknown_scope: scope,
        rejected_targets: [
          { definition_id: 'def:v1:b', reason: 'b' },
          { definition_id: 'def:v1:a', reason: 'a' }
        ]
      }
      forward = described_class.new(
        **attributes, target_definition_ids: %w[def:v1:b def:v1:a], evidence_ids: %w[evidence:b evidence:a]
      )
      reverse = described_class.new(
        **attributes, rejected_targets: attributes.fetch(:rejected_targets).reverse,
                      target_definition_ids: %w[def:v1:a def:v1:b def:v1:a],
                      evidence_ids: %w[evidence:a evidence:b evidence:a]
      )

      expect(reverse).to eq(forward)
      expect(reverse.to_h).to eq(forward.to_h)
    end
  end

  describe Necropsy::ResolutionRecord do
    it 'retains provenance for a complete empty resolution and round-trips it' do
      resolution = Necropsy::Resolution.new(
        call_site_id: 'call:v1:none', target_definition_ids: [], status: :complete
      )
      record = described_class.new(
        resolution: resolution, producer: :name_resolution, producer_version: '2.1.0',
        assumptions: %w[closed_world loaded_files closed_world]
      )

      expect(record).to have_attributes(
        producer: 'name_resolution', producer_version: '2.1.0',
        assumptions: %w[closed_world loaded_files]
      )
      expect(record.identity_key).to eq(
        ['call:v1:none', 'name_resolution', '2.1.0', %w[closed_world loaded_files]]
      )
      expect(described_class.from_h(record.to_h)).to eq(record)
    end

    it 'rejects missing provenance and malformed resolutions' do
      expect do
        described_class.new(resolution: {}, producer: :name_resolution)
      end.to raise_error(KeyError, /call_site_id/)
      expect do
        described_class.new(
          resolution: Necropsy::Resolution.new(
            call_site_id: 'call:v1:none', target_definition_ids: [], status: :complete
          ),
          producer: ''
        )
      end.to raise_error(ArgumentError, /producer/)
    end
  end

  describe Necropsy::Evidence do
    let(:legacy_values) { [:spec, :call_edge, 0.5, 'legacy details', { 'line' => 3 }] }

    it 'preserves legacy keyword, five-positional new, and bracket construction' do
      keyword = described_class.new(
        analyzer: :spec, kind: :call_edge, weight: 0.5,
        details: 'legacy details', metadata: { 'line' => 3 }
      )

      expect(described_class.new(*legacy_values)).to eq(keyword)
      expect(described_class[*legacy_values]).to eq(keyword)
      expect(keyword).to have_attributes(grade: nil, evidence_id: nil, assumptions: [])
      expect(keyword.to_h).to include('grade' => nil, 'evidence_id' => nil)
      expect(keyword.with(evidence_id: 'evidence:v1:legacy')).to have_attributes(
        grade: nil, evidence_id: 'evidence:v1:legacy'
      )
    end

    it 'supports full positional construction with normalized provenance' do
      full = [
        :spec, :call_edge, 0.5, 'details', {}, 'evidence:v1:manual', :name_resolution, '1.0.0',
        :exact, :call, 'app/sample.rb:3', %w[loaded closed loaded], scope
      ]

      expect(described_class[*full]).to eq(described_class.new(*full))
      expect(described_class.new(*full)).to have_attributes(
        evidence_id: 'evidence:v1:manual', producer: :name_resolution, producer_version: '1.0.0',
        grade: :exact, relation: :call, assumptions: %w[closed loaded], scope: scope
      )
    end

    it 'rejects invalid grades and nil grades on provenance-aware evidence' do
      [:likely, false].each do |grade|
        expect do
          described_class.new(
            analyzer: :spec, kind: :call_edge, weight: 1.0, details: 'bad', metadata: {}, grade: grade
          )
        end.to raise_error(ArgumentError, /grade/)
      end

      %i[producer source scope].each do |attribute|
        expect do
          described_class.new(
            analyzer: :spec, kind: :call_edge, weight: 1.0, details: 'bad', metadata: {},
            grade: nil, **{ attribute => false }
          )
        end.to raise_error(ArgumentError, /legacy/)
      end
    end

    it 'requires complete provenance on graded evidence' do
      attributes = {
        analyzer: :spec, kind: :call_edge, weight: 1.0, details: 'graded', metadata: {},
        producer: :spec, producer_version: '1', grade: :exact, relation: :call_edge,
        source: {}, scope: {}
      }

      %i[producer producer_version relation source scope].each do |attribute|
        expect { described_class.new(**attributes, attribute => nil) }
          .to raise_error(ArgumentError, /requires producer/)
      end
    end

    it 'rejects non-finite weights and unbounded or cyclic payloads' do
      [Float::NAN, Float::INFINITY, 'not-a-number'].each do |weight|
        expect do
          described_class.new(
            analyzer: :spec, kind: :call_edge, weight: weight, details: 'bad weight', metadata: {}
          )
        end.to raise_error(ArgumentError, /weight|Float/)
      end

      cyclic = {}
      cyclic['self'] = cyclic
      expect do
        described_class.new(
          analyzer: :spec, kind: :call_edge, weight: 1.0, details: 'cyclic', metadata: cyclic
        )
      end.to raise_error(Necropsy::BoundedCanonicalizer::CycleError)
      expect do
        described_class.new(
          analyzer: :spec, kind: :call_edge, weight: 1.0,
          details: 'x' * 4_097, metadata: {}
        )
      end.to raise_error(ArgumentError, /details/)
    end
  end

  describe Necropsy::AnalyzerProfile do
    let(:legacy_values) { [:spec, :static, :partial, 'legacy profile'] }

    it 'preserves legacy constructors and supports the full positional shape' do
      keyword = described_class.new(
        name: :spec, kind: :static, soundness: :partial, description: 'legacy profile'
      )
      full = [*legacy_values, '1.2.0', %w[zeta alpha zeta]]

      expect(described_class.new(*legacy_values)).to eq(keyword)
      expect(described_class[*legacy_values]).to eq(keyword)
      expect(keyword).to have_attributes(version: nil, assumptions: [])
      expect(described_class.new(*full)).to have_attributes(
        version: '1.2.0', assumptions: %w[alpha zeta]
      )
      expect(described_class[*full]).to eq(described_class.new(*full))
    end

    it 'rejects unknown enums and unbounded descriptions' do
      expect do
        described_class.new(name: :spec, kind: :other, soundness: :partial, description: 'invalid')
      end.to raise_error(ArgumentError, /kind/)
      expect do
        described_class.new(name: :spec, kind: :static, soundness: :perfect, description: 'invalid')
      end.to raise_error(ArgumentError, /soundness/)
      expect do
        described_class.new(
          name: :spec, kind: :static, soundness: :partial,
          description: 'x' * 4_097
        )
      end.to raise_error(ArgumentError, /description/)
    end
  end

  describe Necropsy::AnalyzerResult do
    let(:resolution) do
      Necropsy::Resolution.new(
        call_site_id: 'call:v1:result', target_definition_ids: [], status: :complete
      )
    end

    it 'defaults new collections and wraps bare resolutions as legacy records' do
      result = described_class.new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, resolutions: [resolution]
      )

      expect(result.evidences).to eq([])
      expect(result.resolutions).to contain_exactly(
        have_attributes(resolution: resolution, producer: 'legacy', producer_version: nil, assumptions: [])
      )
    end

    it 'preserves four/five positional and full positional construction' do
      legacy_four = [[], [], {}, {}]
      legacy_five = [[], [], {}, {}, [:blocker]]
      record = Necropsy::ResolutionRecord.new(resolution: resolution, producer: :spec, producer_version: '1')
      full = [[], [], {}, {}, [], [record], [:evidence]]

      expect(described_class[*legacy_four]).to eq(described_class.new(*legacy_four))
      expect(described_class.new(*legacy_four)).to have_attributes(
        blockers: [], resolutions: nil, evidences: [], derived_call_sites: []
      )
      expect(described_class[*legacy_five]).to eq(described_class.new(*legacy_five))
      expect(described_class.new(*legacy_five)).to have_attributes(blockers: [:blocker], resolutions: nil)
      expect(described_class[*full]).to eq(described_class.new(*full))
      expect(described_class.new(*full)).to have_attributes(
        resolutions: [record], evidences: [:evidence], derived_call_sites: []
      )
    end

    it 'distinguishes legacy omission from an explicit empty native result' do
      legacy = described_class.new(edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {})
      native = described_class.new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {}, resolutions: []
      )

      expect(legacy.resolutions).to be_nil
      expect(native.resolutions).to eq([])
      expect(described_class.empty.resolutions).to eq([])
    end

    it 'preserves conflicting producer records for the same call site deterministically' do
      complete = Necropsy::ResolutionRecord.new(resolution: resolution, producer: :first, producer_version: '1')
      unknown = Necropsy::ResolutionRecord.new(
        resolution: Necropsy::Resolution.new(
          call_site_id: resolution.call_site_id, target_definition_ids: [], status: :unknown,
          unknown_scope: scope
        ),
        producer: :second, producer_version: '1'
      )

      forward = described_class.new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {},
        resolutions: [unknown, complete]
      )
      reverse = described_class.new(
        edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {},
        resolutions: [complete, unknown]
      )

      expect(forward.resolutions).to eq(reverse.resolutions)
      expect(forward.resolutions.map(&:producer)).to contain_exactly('first', 'second')
    end

    it 'orders mixed producer versions and complete record contents deterministically' do
      legacy = Necropsy::ResolutionRecord.new(resolution: resolution, producer: :spec)
      versioned = Necropsy::ResolutionRecord.new(
        resolution: resolution, producer: :spec, producer_version: '1'
      )
      scoped = %w[b* a*].map do |pattern|
        Necropsy::ResolutionRecord.new(
          resolution: Necropsy::Resolution.new(
            call_site_id: resolution.call_site_id,
            target_definition_ids: [],
            status: :unknown,
            unknown_scope: { scope_kind: :message, scope_value: pattern, match: :glob }
          ),
          producer: :spec,
          producer_version: '2'
        )
      end
      attributes = { edge_evidences: [], alive_evidences: [], uncertainties: {}, observation: {} }

      forward = described_class.new(**attributes, resolutions: [legacy, versioned, *scoped])
      reverse = described_class.new(**attributes, resolutions: [*scoped.reverse, versioned, legacy])

      expect(reverse.resolutions).to eq(forward.resolutions)
    end
  end
end
