require "spec"
require "file_utils"
require "../src/atomic_file"

# The whole point: a reader must never observe a partially written file, because
# one of those readers is the UI loading a texture (a truncated JPEG decodes with
# pieces missing and the broken texture is cached), and another is
# `omarchy-theme-set` scanning the theme folder for wallpapers.
describe AtomicFile do
  it "creates the destination only once the content is complete" do
    dir = File.join(Dir.tempdir, "atomic-spec-#{Process.pid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "out.jpg")

    inside = AtomicFile.write(dest) do |tmp|
      File.write(tmp, "half")
      # a reader looking right now must see nothing at the destination
      File.exists?(dest).should be_false
    end

    inside.should be_nil
    File.exists?(dest).should be_true
    File.read(dest).should eq "half"
    Dir.children(dir).should eq ["out.jpg"] # no temporary left behind
    FileUtils.rm_rf(dir)
  end

  it "replaces an existing destination atomically" do
    dir = File.join(Dir.tempdir, "atomic-spec2-#{Process.pid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "out.jpg")
    File.write(dest, "old")

    AtomicFile.write(dest) do |tmp|
      File.write(tmp, "new content")
      File.read(dest).should eq "old" # untouched until the rename
    end

    File.read(dest).should eq "new content"
    FileUtils.rm_rf(dir)
  end

  it "can keep a non-image temporary name, so directory scans ignore it" do
    dir = File.join(Dir.tempdir, "atomic-spec3-#{Process.pid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "wallpaper.jpg")
    temporary = ""

    AtomicFile.write(dest, suffix: ".part") do |tmp|
      temporary = tmp
      File.write(tmp, "x")
    end

    # while writing, the temporary must not look like a wallpaper
    temporary.ends_with?(".part").should be_true
    temporary.ends_with?(".jpg").should be_false
    FileUtils.rm_rf(dir)
  end

  it "cleans up the temporary when the block raises" do
    dir = File.join(Dir.tempdir, "atomic-spec4-#{Process.pid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "out.jpg")

    expect_raises(Exception, "boom") do
      AtomicFile.write(dest) do |tmp|
        File.write(tmp, "partial")
        raise "boom"
      end
    end

    File.exists?(dest).should be_false
    Dir.children(dir).should be_empty
    FileUtils.rm_rf(dir)
  end

  it "finds temporaries abandoned by a killed process" do
    dir = File.join(Dir.tempdir, "atomic-spec5-#{Process.pid}")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(File.join(dir, "nested"))
    File.write(File.join(dir, "nested", ".thumb.123.4.part.jpg"), "leftover")
    File.write(File.join(dir, "keep.jpg"), "real")

    AtomicFile.stale(dir).size.should eq 1
    FileUtils.rm_rf(dir)
  end
end
