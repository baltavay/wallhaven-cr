require "spec"
require "file_utils"
require "../src/images"
require "../src/spawn"

# Fixture for the image specs: one 2000x1200 JPEG, built with whichever backend
# is active.
module ImageFixture
  @@dir : String?
  @@source : String?

  def self.dir : String
    @@dir ||= begin
      dir = File.join(Dir.tempdir, "wallhaven-cr-images-#{Process.pid}")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  def self.source : String
    @@source ||= begin
      path = File.join(dir, "source.jpg")
      result = if ImageOps.vips?
                 Spawn.run("vips", ["black", path, "2000", "1200"])
               else
                 Spawn.run(Process.find_executable("magick") || Process.find_executable("convert") || "convert",
                   ["-size", "2000x1200", "xc:gray", path])
               end
      raise "cannot build the image fixture: #{result.message}" unless result.success?
      path
    end
  end

  def self.cleanup : Nil
    FileUtils.rm_rf(dir)
  end
end

# `ImageOps` is the contract every thumbnail, preview and wallpaper version goes
# through. The backend (libvips or ImageMagick) is picked at runtime, so what
# must hold is the contract: exact output dimensions, no upscaling, and no
# intermediate files left behind.
describe ImageOps do
  it "uses a supported backend and reads the source dimensions" do
    ["vips", "magick", "convert"].should contain ImageOps.backend_name
    File.exists?(ImageFixture.source).should be_true
    ImageOps.identify(ImageFixture.source).should eq({2000_i64, 1200_i64})
  end

  it "bounds the editor preview and never upscales it" do
    dst = File.join(ImageFixture.dir, "preview.jpg")
    ImageOps.preview(ImageFixture.source, dst, 640)
    ImageOps.identify(dst).should eq({640_i64, 384_i64})

    small = File.join(ImageFixture.dir, "small.jpg")
    ImageOps.crop_resize(ImageFixture.source, small, {0_i64, 0_i64, 320_i64, 180_i64}, 320, 180)
    ImageOps.preview(small, dst, 2048)
    ImageOps.identify(dst).should eq({320_i64, 180_i64})
  end

  it "renders a cropped version at exactly the requested size, whatever the crop aspect" do
    dst = File.join(ImageFixture.dir, "crop.jpg")
    # a 3:1 slice of a 5:3 source, forced to 1920x1080
    ImageOps.crop_resize(ImageFixture.source, dst, {100_i64, 200_i64, 1500_i64, 500_i64}, 1920, 1080)
    ImageOps.identify(dst).should eq({1920_i64, 1080_i64})
  end

  it "leaves no intermediate files next to its output" do
    dir = File.join(ImageFixture.dir, "clean")
    FileUtils.mkdir_p(dir)
    ImageOps.crop_resize(ImageFixture.source, File.join(dir, "version.jpg"),
      {0_i64, 0_i64, 1000_i64, 600_i64}, 1280, 768)
    ImageOps.preview(ImageFixture.source, File.join(dir, "thumb.jpg"), 128)

    Dir.children(dir).sort.should eq ["thumb.jpg", "version.jpg"]
  end

  it "raises a readable error for a file it cannot read" do
    expect_raises(ImageOps::Error, /cannot read/) do
      ImageOps.identify(File.join(ImageFixture.dir, "does-not-exist.jpg"))
    end
  end
end

Spec.after_suite do
  ImageFixture.cleanup
end
