# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Paperclip::LazyThumbnail do
  let(:directory) { Dir.mktmpdir('vips-quality-spec-') }
  let(:source) { Tempfile.new(['upload', '.tmp'], directory) }
  let(:media) { MediaAttachment.new }
  let(:attachment) { instance_double(Paperclip::Attachment, instance: media, instance_read: filename) }
  let(:geometry_parser) do
    Class.new do
      def self.from_file(file)
        image = Vips::Image.new_from_file(file.path)
        Paperclip::Geometry.new(image.width, image.height)
      end
    end
  end
  let(:options) { { pixels: 256 * 192, style: :original, format: format, file_geometry_parser: geometry_parser } }
  let(:output) { described_class.new(source, options, attachment).make }

  before do
    image = Vips::Image.black(512, 384, bands: 3).copy(interpretation: :srgb)
    image.write_to_file("#{source.path}#{source_extension}", **(source_extension == '.jpg' ? { Q: 100 } : {}))
    File.binwrite(source.path, File.binread("#{source.path}#{source_extension}"))
  end

  after do
    output.close!
    source.close!
    FileUtils.remove_entry(directory)
  end

  [
    ['original .jpg', nil, 'upload.jpg', '.jpg'],
    ['original .jpeg', nil, 'upload.jpeg', '.jpg'],
    ['original uppercase .JPEG', nil, 'upload.JPEG', '.jpg'],
    ['explicit jpg conversion', 'jpg', 'upload.png', '.png'],
    ['explicit jpeg conversion', 'jpeg', 'upload.png', '.png'],
  ].each do |label, requested_format, uploaded_name, extension|
    context "with #{label}" do
      let(:format) { requested_format }
      let(:filename) { uploaded_name }
      let(:source_extension) { extension }

      it 'resizes the actual output and uses JPEG quality90 quantization tables' do
        actual = Vips::Image.new_from_file(output.path)
        expect([actual.width, actual.height]).to eq [256, 192]

        reference = Vips::Image.thumbnail(source.path, 256, height: 192, size: :down).copy_memory
        reference90 = File.join(directory, 'reference90.jpg')
        reference75 = File.join(directory, 'reference75.jpg')
        reference.write_to_file(reference90, Q: 90, interlace: true)
        reference.write_to_file(reference75, Q: 75, interlace: true)

        expect(jpeg_quantization(output.path)).to eq jpeg_quantization(reference90)
        expect(jpeg_quantization(output.path)).to_not eq jpeg_quantization(reference75)
      end
    end
  end

  context 'with an unchanged PNG output format' do
    let(:format) { nil }
    let(:filename) { 'upload.png' }
    let(:source_extension) { '.png' }

    it 'keeps PNG format while resizing' do
      expect(File.binread(output.path, 8)).to eq "\x89PNG\r\n\x1A\n".b
      image = Vips::Image.new_from_file(output.path)
      expect([image.width, image.height]).to eq [256, 192]
    end
  end

  private

  def jpeg_quantization(path)
    bytes = File.binread(path)
    raise 'Expected JPEG SOI' unless bytes.byteslice(0, 2) == "\xFF\xD8".b

    offset = 2
    tables = {}
    while offset < bytes.bytesize
      raise 'Invalid JPEG marker' unless bytes.getbyte(offset) == 255

      offset += 1
      offset += 1 while bytes.getbyte(offset) == 255
      marker = bytes.getbyte(offset)
      offset += 1
      break if [0xDA, 0xD9].include?(marker)
      next if [0x01, 0xD8, *0xD0..0xD7].include?(marker)

      length = bytes.byteslice(offset, 2).unpack1('n')
      raise 'Invalid JPEG segment' unless length && length >= 2 && offset + length <= bytes.bytesize

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
    raise 'Missing DQT' if tables.empty?

    tables
  end
end
