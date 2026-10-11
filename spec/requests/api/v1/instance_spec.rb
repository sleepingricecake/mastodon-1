# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Instances' do
  include_context 'with API authentication'

  describe 'GET /api/v1/instance' do
    context 'when not logged in' do
      it 'returns http success and json' do
        get api_v1_instance_path

        expect(response)
          .to have_http_status(200)
        expect(response.content_type)
          .to start_with('application/json')

        expect(response.parsed_body)
          .to be_present
          .and include(title: 'Mastodon')
          .and include_media_limits
      end
    end

    context 'when logged in' do
      it 'returns http success and json' do
        get api_v1_instance_path, headers: headers

        expect(response)
          .to have_http_status(200)
        expect(response.content_type)
          .to start_with('application/json')

        expect(response.parsed_body)
          .to be_present
          .and include(title: 'Mastodon')
          .and include_media_limits
      end
    end

    def include_media_limits
      include(
        configuration: include(
          media_attachments: include(
            image_size_limit: 16.megabytes,
            image_matrix_limit: 104_857_600,
            video_size_limit: 99.megabytes,
            video_matrix_limit: 8_294_400,
            video_frame_rate_limit: 120
          )
        )
      )
    end
  end
end
