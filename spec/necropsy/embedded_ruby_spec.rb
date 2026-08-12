# frozen_string_literal: true

RSpec.describe Necropsy::EmbeddedRuby do
  it 'preserves line numbers while removing markup and ERB comments' do
    source = <<~ERB
      <p>not_ruby</p>
      <%# hidden_call %>
      <%= visible_call %>
      <% object.perform! # ignored_comment_call %>
    ERB

    extracted = described_class.extract(source)

    expect(extracted.lines.length).to eq(source.lines.length)
    expect(extracted).not_to include('not_ruby', 'hidden_call', 'ignored_comment_call')
    expect(extracted.lines[2]).to include('visible_call')
    expect(described_class.call_names(source)).to contain_exactly('visible_call', 'object', 'perform!')
  end
end
