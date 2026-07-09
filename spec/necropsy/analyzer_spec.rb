# frozen_string_literal: true

RSpec.describe Necropsy::Analyzer do
  it 'requires concrete analyzers to implement analyze and profile' do
    analyzer = described_class.new

    expect { analyzer.analyze(nil, nil) }.to raise_error(NotImplementedError, /must implement #analyze/)
    expect { analyzer.profile }.to raise_error(NotImplementedError, /must implement #profile/)
  end
end
