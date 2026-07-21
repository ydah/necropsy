# frozen_string_literal: true

RSpec.describe Necropsy::Guardrail::Diff do
  it 'returns changed files from git diff output' do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(["app/model.rb\nspec/model_spec.rb\n", '', status])

    expect(described_class.changed_files(root: '/repo', diff_base: 'origin/main')).to eq(
      Set['app/model.rb', 'spec/model_spec.rb']
    )
    expect(Open3).to have_received(:capture3).with(
      'git',
      '-C',
      '/repo',
      'diff',
      '--name-only',
      'origin/main...HEAD'
    )
  end

  it 'raises a domain error when git diff fails' do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return(['', 'fatal: bad revision', status])

    expect do
      described_class.changed_files(root: '/repo', diff_base: 'main')
    end.to raise_error(Necropsy::Error, /bad revision/)
  end
end
