require "spec"
require "file_utils"

# Keep the writes out of the real theme folder.
ENV["WALLHAVEN_CR_THEME_DIR"] = File.join(Dir.tempdir, "wallhaven-cr-theme-#{Process.pid}")

require "../src/monitors"

module ThemeFixture
  # The theme folder the app copies into…
  def self.dir : String
    Omarchy.backgrounds_dir
  end

  # …kept separate from the sources being copied, so the content scan cannot find
  # the source itself.
  def self.src_dir : String
    @@src_dir ||= begin
      dir = File.join(Dir.tempdir, "wallhaven-cr-theme-src-#{Process.pid}")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  @@src_dir : String?
  @@counter = 0

  # A distinct source file per call, so examples cannot see each other's content.
  def self.source(bytes : Int32 = 1000) : String
    @@counter += 1
    path = File.join(src_dir, "src-#{@@counter}.jpg")
    File.write(path, ("v#{@@counter}-" * bytes))
    path
  end

  def self.reset! : Nil
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
  end

  def self.names(prefix : String) : Array(String)
    Dir.children(dir).select { |f| f.starts_with?(prefix) }.sort
  end

  def self.cleanup : Nil
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(src_dir)
  end
end

# Adding a wallpaper version to the theme must be idempotent: the same version can
# never land twice, while a genuinely different version must not be lost. Identity
# is the file's content, not its name.
describe Omarchy do
  it "adds a version once and reports it as already present afterwards" do
    ThemeFixture.reset!
    source = ThemeFixture.source

    first = Omarchy.add_background(source, "wallhaven-abc")
    first.added?.should be_true
    first.path.should end_with "wallhaven-abc.jpg"

    second = Omarchy.add_background(source, "wallhaven-abc")
    second.added?.should be_false
    second.path.should eq first.path
    ThemeFixture.names("wallhaven-abc").should eq ["wallhaven-abc.jpg"]
  end

  it "keeps a different version under the same name as a numbered sibling, without ever triplicating" do
    ThemeFixture.reset!
    a = ThemeFixture.source
    b = ThemeFixture.source

    Omarchy.add_background(a, "wallhaven-def").added?.should be_true
    other = Omarchy.add_background(b, "wallhaven-def")
    other.added?.should be_true
    other.path.should end_with "wallhaven-def-1.jpg"
    ThemeFixture.names("wallhaven-def").should eq ["wallhaven-def-1.jpg", "wallhaven-def.jpg"]

    # re-adding the second version must find its sibling, not create -2
    third = Omarchy.add_background(b, "wallhaven-def")
    third.added?.should be_false
    third.path.should eq other.path
    ThemeFixture.names("wallhaven-def").should eq ["wallhaven-def-1.jpg", "wallhaven-def.jpg"]
  end

  it "recognises the same version when it is already there under another name" do
    ThemeFixture.reset!
    source = ThemeFixture.source
    # as if added by an older build, or dropped in by hand
    legacy = File.join(ThemeFixture.dir, "wallhaven-legacy-1.jpg")
    File.copy(source, legacy)

    result = Omarchy.add_background(source, "wallhaven-legacy-crop1.jpg")
    result.added?.should be_false
    result.path.should eq legacy
    ThemeFixture.names("wallhaven-legacy").should eq ["wallhaven-legacy-1.jpg"]
  end

  it "always writes an image extension, since omarchy's search filters on one" do
    ThemeFixture.reset!
    Omarchy.add_background(ThemeFixture.source, "wallhaven-noext").path.should end_with ".jpg"
  end

  it "names the original and each crop version stably" do
    Omarchy.version_name("wallhaven-xyz", "/x/1.png").should eq "wallhaven-xyz.png"
    Omarchy.version_name("wallhaven-xyz", "/x/1.png", 0_i64).should eq "wallhaven-xyz-crop1.png"
    Omarchy.version_name("wallhaven-xyz", "/x/1.jpg", 2_i64).should eq "wallhaven-xyz-crop3.jpg"
  end


  it "removes a version again, leaving the other versions alone" do
    ThemeFixture.reset!
    a = ThemeFixture.source
    b = ThemeFixture.source
    Omarchy.add_background(a, "wallhaven-del-a")
    Omarchy.add_background(b, "wallhaven-del-b")
    Omarchy.background_names.should contain "wallhaven-del-a.jpg"
    Omarchy.background_names.should contain "wallhaven-del-b.jpg"

    removed = Omarchy.remove_background(a)
    removed.map { |p| File.basename(p) }.should eq ["wallhaven-del-a.jpg"]

    names = Omarchy.background_names
    names.should_not contain "wallhaven-del-a.jpg"
    names.should contain "wallhaven-del-b.jpg"
    # the source in the library is untouched, so it can be added again
    File.exists?(a).should be_true
    Omarchy.add_background(a, "wallhaven-del-a").added?.should be_true
  end

  it "removes every copy of a version, whatever it is named" do
    ThemeFixture.reset!
    source = ThemeFixture.source
    # both copies made by hand, because `add_background` would refuse to create a
    # second one now that it compares content
    File.copy(source, File.join(ThemeFixture.dir, "old-name.jpg"))
    File.copy(source, File.join(ThemeFixture.dir, "wallhaven-del-c.jpg"))

    removed = Omarchy.remove_background(source).map { |p| File.basename(p) }.sort
    removed.should eq ["old-name.jpg", "wallhaven-del-c.jpg"]
    ThemeFixture.names("wallhaven-del-c").should be_empty
  end

  it "reports nothing removed when the version is not in the theme" do
    ThemeFixture.reset!
    Omarchy.remove_background(ThemeFixture.source).should be_empty
  end

  it "lists what is already in the theme folder" do
    ThemeFixture.reset!
    Omarchy.add_background(ThemeFixture.source, "wallhaven-listed")
    names = Omarchy.background_names
    names.should contain "wallhaven-listed.jpg"
  end
end

Spec.after_suite do
  ThemeFixture.cleanup
end
