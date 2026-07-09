# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Diff do
  it 'returns changed files from git diff output' do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture2).and_return(["app/model.rb\nspec/model_spec.rb\n", status])

    expect(described_class.changed_files(root: '/repo', diff_base: 'origin/main')).to eq(
      Set['app/model.rb', 'spec/model_spec.rb']
    )
    expect(Open3).to have_received(:capture2).with(
      'git',
      '-C',
      '/repo',
      'diff',
      '--name-only',
      'origin/main...HEAD'
    )
  end

  it 'returns an empty set when git diff fails' do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture2).and_return(['fatal', status])

    expect(described_class.changed_files(root: '/repo', diff_base: 'main')).to eq(Set.new)
  end
end
