# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Quarantine do
  it 'suggests quarantine annotations for findings at the requested confidence' do
    low = finding(id: 'Sample#low', confidence: :low, file: 'app/sample.rb', line: 2)
    high = finding(id: 'Sample#high', confidence: :high, file: 'app/sample.rb', line: 5)
    report = report_with_findings([low, high], root: '/repo')

    suggestions = described_class.new(report: report, root: '/repo').suggestions(min_confidence: :high)

    expect(suggestions.map { |suggestion| suggestion[:finding] }).to eq([high])
    expect(suggestions.first[:annotation]).to match(/\A# necropsy:quarantine since=\d{4}-\d{2}-\d{2}\z/)
    expect(suggestions.first[:path]).to eq('/repo/app/sample.rb')
  end

  it 'writes annotations above target methods without duplicating existing annotations' do
    source = <<~RUBY
      class Sample
        def first
        end

        # necropsy:quarantine since=2000-01-01
        def second
        end
      end
    RUBY

    with_project(files: { 'app/sample.rb' => source }) do |root|
      first = finding(id: 'Sample#first', confidence: :high, file: 'app/sample.rb', line: 2)
      second = finding(id: 'Sample#second', confidence: :high, file: 'app/sample.rb', line: 6)
      report = report_with_findings([first, second], root: root)

      described_class.new(report: report, root: root).write(min_confidence: :high)

      lines = File.readlines(File.join(root, 'app/sample.rb'), chomp: true)
      expect(lines[1]).to match(/  # necropsy:quarantine since=/)
      expect(lines.grep(/necropsy:quarantine/).length).to eq(2)
    end
  end
end
