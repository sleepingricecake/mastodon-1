# frozen_string_literal: true

# Run inside the exact app image: bundle exec ruby deployment/mochitodon/verify_runtime.rb
require 'bundler/setup'
require 'resolv'
require 'openssl'
require 'open3'
require 'vips'

resolv_version = Gem.loaded_specs.fetch('resolv').version
raise 'Active resolv must be at least0.7.2' if resolv_version < Gem::Version.new('0.7.2')
raise 'Ruby must be4.0.7 for this reviewed custom image' unless RUBY_VERSION == '4.0.7'
raise 'OpenSSL3 runtime required' unless OpenSSL::OPENSSL_LIBRARY_VERSION.start_with?('OpenSSL 3.')
raise 'Reviewed Vips8.18.7 required' unless Vips.version_string == '8.18.7'

ffmpeg, ffmpeg_status = Open3.capture2('ffmpeg', '-version')
raise 'Reviewed FFmpeg9.0.2 required' unless ffmpeg_status.success? && ffmpeg.lines.first.match?(/ffmpeg version (?:n)?9\.0\.2\b/)

puts "PASS: Ruby#{RUBY_VERSION}, active resolv#{resolv_version}, #{OpenSSL::OPENSSL_LIBRARY_VERSION}, Vips#{Vips.version_string}, FFmpeg9.0.2"
