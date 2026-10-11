# frozen_string_literal: true

# Run inside the exact app image: bundle exec ruby deployment/mochitodon/verify_runtime.rb
require 'bundler/setup'
require 'rbconfig'
require 'resolv'
require 'openssl'
require 'open3'
require 'vips'

resolv_features = $LOADED_FEATURES.select { |path| path.end_with?('/resolv.rb') }
expected_resolv = File.join(RbConfig::CONFIG.fetch('rubylibdir'), 'resolv.rb')
raise 'Reviewed Ruby bundled resolv required' unless resolv_features.length == 1 && File.realpath(resolv_features.first) == File.realpath(expected_resolv)

# Ruby's bundled library can load without a Gem.loaded_specs entry.
# Check the active implementation; a gem registration, when present, must agree.
resolv_version = Gem::Version.new(Resolv::VERSION)
resolv_spec = Gem.loaded_specs['resolv']
raise 'Active resolv and gem registration disagree' if resolv_spec && resolv_spec.version != resolv_version
raise 'Active resolv must be at least0.7.2' if resolv_version < Gem::Version.new('0.7.2')
raise 'Ruby must be4.0.7 for this reviewed custom image' unless RUBY_VERSION == '4.0.7'
raise 'OpenSSL3 runtime required' unless OpenSSL::OPENSSL_LIBRARY_VERSION.start_with?('OpenSSL 3.')
raise 'Reviewed Vips8.18.7 required' unless Vips.version_string == '8.18.7'

ffmpeg, ffmpeg_status = Open3.capture2('ffmpeg', '-version')
raise 'Reviewed FFmpeg9.0.2 required' unless ffmpeg_status.success? && ffmpeg.lines.first.match?(/ffmpeg version (?:n)?9\.0\.2\b/)

puts "PASS: Ruby#{RUBY_VERSION}, active resolv#{resolv_version}, #{OpenSSL::OPENSSL_LIBRARY_VERSION}, Vips#{Vips.version_string}, FFmpeg9.0.2"
