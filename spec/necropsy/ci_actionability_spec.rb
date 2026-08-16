# frozen_string_literal: true

RSpec.describe 'CI actionability contract' do
  it 'fails the default check for a new review candidate and passes after baselining it' do
    root = create_project(files: {
                            'app/sample.rb' => 'class CiActionability; def dead; end; end'
                          })

    expect do
      expect(Necropsy::CLI.run(['check', '--root', root])).to eq(1)
    end.to output(/unreachable|review_candidate/).to_stdout

    expect(Necropsy::CLI.run(['baseline', '--root', root])).to eq(0)
    expect(Necropsy::CLI.run(['check', '--root', root])).to eq(0)
  end
end
