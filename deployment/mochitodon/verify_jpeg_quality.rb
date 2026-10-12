# frozen_string_literal: true

# Standalone integration check: bundle exec ruby deployment/mochitodon/verify_jpeg_quality.rb
# It does not boot Rails, read production env, connect to DB, or send network requests.
require 'bundler/setup'
require 'active_support/all'
require 'paperclip'
require 'tmpdir'
require 'tempfile'

root = File.expand_path('../..', __dir__)
require File.join(root, 'config/initializers/vips')
require File.join(root, 'lib/paperclip/vips_lazy_thumbnail')

class FixtureGeometryParser
  def self.from_file(file)
    image = Vips::Image.new_from_file(file.path)
    Paperclip::Geometry.new(image.width, image.height)
  end
end

AttachmentFixture = Struct.new(:instance, :file_name) do
  def instance_read(attribute)
    raise "Unexpected attachment attribute: #{attribute}" unless attribute == :file_name

    file_name
  end
end

def quantization_tables(path)
  bytes = File.binread(path)
  raise 'JPEG SOI missing' unless bytes.byteslice(0, 2) == "\xFF\xD8".b

  offset = 2
  tables = {}
  while offset < bytes.bytesize
    raise 'Malformed marker' unless bytes.getbyte(offset) == 255

    offset += 1
    offset += 1 while bytes.getbyte(offset) == 255
    marker = bytes.getbyte(offset)
    offset += 1
    break if [0xDA, 0xD9].include?(marker)
    next if [0x01, 0xD8, *0xD0..0xD7].include?(marker)

    length = bytes.byteslice(offset, 2).unpack1('n')
    raise 'Malformed segment length' unless length && length >= 2 && offset + length <= bytes.bytesize

    payload = bytes.byteslice(offset + 2, length - 2)
    offset += length
    next unless marker == 0xDB

    cursor = 0
    while cursor < payload.bytesize
      info = payload.getbyte(cursor)
      precision = info >> 4
      raise 'Invalid DQT precision' unless [0, 1].include?(precision)

      size = 64 * (precision + 1)
      table = payload.byteslice(cursor + 1, size)
      raise 'Truncated DQT' unless table&.bytesize == size

      tables[info & 0x0F] = table
      cursor += 1 + size
    end
  end
  raise 'JPEG DQT missing' if tables.empty?

  tables
end

Dir.mktmpdir('mastodon-jpeg90-') do |directory|
  width = 512
  height = 384
  pixels = String.new(encoding: Encoding::BINARY)
  height.times do |y|
    width.times { |x| pixels << [x % 256, y % 256, (x * 3 + y * 5) % 256].pack('C*') }
  end
  image = Vips::Image.new_from_memory(pixels, width, height, 3, :uchar).copy(interpretation: :srgb)
  seed_jpeg = File.join(directory, 'seed.jpg')
  seed_png = File.join(directory, 'seed.png')
  image.write_to_file(seed_jpeg, Q: 100)
  image.write_to_file(seed_png)
  target_pixels = 256 * 192
  # Materialize a separate reference so the comparison does not reuse a
  # sequential thumbnail pipeline already consumed by the processor.
  reference = image.resize(0.5).copy_memory
  reference90 = File.join(directory, 'reference90.jpg')
  reference75 = File.join(directory, 'reference75.jpg')
  reference.write_to_file(reference90, Q: 90, interlace: true)
  reference.write_to_file(reference75, Q: 75, interlace: true)
  tables90 = quantization_tables(reference90)
  tables75 = quantization_tables(reference75)
  cases = [
    ['original .jpg', nil, 'uploaded.jpg', seed_jpeg],
    ['original .jpeg', nil, 'uploaded.jpeg', seed_jpeg],
    ['original .JPEG', nil, 'uploaded.JPEG', seed_jpeg],
    ['explicit jpg', 'jpg', 'uploaded.png', seed_png],
    ['explicit jpeg', 'jpeg', 'uploaded.png', seed_png],
  ]
  cases.each do |label, format, uploaded_name, seed|
    # The tempfile suffix deliberately differs from the attachment filename.
    source = Tempfile.new(['input-', '.tmp'], directory)
    File.binwrite(source.path, File.binread(seed))
    attachment = AttachmentFixture.new(Object.new.tap { |object| object.define_singleton_method(:local?) { true } }, uploaded_name)
    options = { pixels: target_pixels, file_geometry_parser: FixtureGeometryParser, style: :original }
    options[:format] = format if format
    output = Paperclip::LazyThumbnail.new(source, options, attachment).make
    transformed = Vips::Image.new_from_file(output.path)
    raise "#{label}: unexpected dimensions" unless [transformed.width, transformed.height] == [256, 192]

    actual_tables = quantization_tables(output.path)
    raise "#{label}: JPEG is not encoded with quality90 tables" unless actual_tables == tables90
    raise "#{label}: indistinguishable from quality75" if actual_tables == tables75

    puts "PASS: #{label}: actual JPEG processing, 256x192, Q90 quantization"
    output.close!
    source.close!
  end
  source = Tempfile.new(['input-', '.tmp'], directory)
  File.binwrite(source.path, File.binread(seed_png))
  attachment = AttachmentFixture.new(Object.new.tap { |object| object.define_singleton_method(:local?) { true } }, 'uploaded.png')
  output = Paperclip::LazyThumbnail.new(source, { pixels: target_pixels, file_geometry_parser: FixtureGeometryParser, style: :original }, attachment).make
  raise 'PNG output changed format' unless File.binread(output.path, 8) == "\x89PNG\r\n\x1A\n".b

  transformed = Vips::Image.new_from_file(output.path)
  raise 'PNG unexpected dimensions' unless [transformed.width, transformed.height] == [256, 192]

  puts 'PASS: non-JPEG PNG remains PNG, 256x192'
  output.close!
  source.close!
end
