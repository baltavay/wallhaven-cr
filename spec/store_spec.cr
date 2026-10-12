require "spec"
require "file_utils"

# Use a throwaway data directory: these specs create and delete real rows.
ENV["WALLHAVEN_CR_DATA"] = File.join(Dir.tempdir, "wallhaven-cr-spec-#{Process.pid}")

require "../src/store"
require "../src/jobs"
require "../src/aether_import"

# The store and the job queue hold the data the app can lose: re-running an
# import must not queue the same wallpaper twice, deleting a version must not
# touch the original, and a killed process must not block the queue forever.
describe "wallhaven-cr storage" do
  before_all do
    FileUtils.rm_rf(ENV["WALLHAVEN_CR_DATA"])
    Db.setup
  end

  after_all do
    FileUtils.rm_rf(ENV["WALLHAVEN_CR_DATA"])
  end

  before_each do
    Db.conn.exec("DELETE FROM jobs")
  end

  it "creates the schema once and reports its version" do
    Store.meta("schema_version").should eq "1"
    Dir.exists?(Config.originals_dir).should be_true
    Dir.exists?(Config.crops_dir).should be_true
  end

  it "keeps favourites when a search result is upserted again" do
    wallpaper = Wallpaper.new("spec-one", "wallhaven")
    wallpaper.url = "https://example.test/one.jpg"
    wallpaper.resolution = "1920x1080"
    Store.upsert_wallpaper(wallpaper)
    Store.set_favorite("spec-one", true)

    # a later search returns the same wallpaper without the favourite flag
    Store.upsert_wallpaper(Wallpaper.new("spec-one", "wallhaven"))

    Store.favorite?("spec-one").should be_true
    Store.favorite_ids.includes?("spec-one").should be_true
    Store.wallpaper("spec-one").not_nil!.url.should eq "https://example.test/one.jpg"
  end

  it "lists the original first and deletes a cropped version on its own" do
    original = WallpaperFile.new("spec-one", "original", File.join(Config.originals_dir, "spec-one.jpg"), 3840, 2160)
    original_id = Store.insert_file(original)
    crop = WallpaperFile.new("spec-one", "crop", File.join(Config.crops_dir, "spec-one_1920x1080_0.jpg"), 1920, 1080)
    crop.crop_index = 0_i64
    crop_id = Store.insert_file(crop)

    files = Store.files_for("spec-one")
    files.map(&.kind).should eq ["original", "crop"]

    Store.delete_file(crop_id)

    remaining = Store.files_for("spec-one")
    remaining.size.should eq 1
    remaining.first.kind.should eq "original"
    remaining.first.id.should eq original_id
  end

  it "requeues jobs left running by a killed process, abandoning only past the attempt limit" do
    fresh = Jobs.enqueue(Jobs::DOWNLOAD, {"wallpaper_id" => "spec-three", "url" => "u"})
    Db.conn.exec("UPDATE jobs SET status = 'running', attempts = 1 WHERE id = ?", fresh)
    ancient = Jobs.enqueue(Jobs::DOWNLOAD, {"wallpaper_id" => "spec-four", "url" => "u"})
    Db.conn.exec("UPDATE jobs SET status = 'running', attempts = ? WHERE id = ?", Jobs::MAX_ATTEMPTS, ancient)

    Jobs.requeue_stale

    Db.conn.query_one("SELECT status FROM jobs WHERE id = ?", fresh, as: String).should eq "queued"
    Db.conn.query_one("SELECT status FROM jobs WHERE id = ?", ancient, as: String).should eq "failed"
  end

  it "records a failure instead of losing the job" do
    job_id = Jobs.enqueue(Jobs::IMPORT_LOCAL, {"path" => "/nonexistent/not-an-image.jpg", "favorite" => true})

    Jobs.drain_once.should be_true

    status, error = Db.conn.query_one(
      "SELECT status, error FROM jobs WHERE id = ?", job_id, as: {String, String?})
    status.should eq "failed"
    error.not_nil!.should contain "no such file"
  end

  it "queues each aether favourite only once, however often the import runs" do
    dir = File.join(ENV["WALLHAVEN_CR_DATA"], "aether-fixture")
    FileUtils.mkdir_p(dir)
    favorites = File.join(dir, "favorites.json")
    File.write(favorites, [
      {"id" => "imp-one", "path" => "https://w.wallhaven.cc/full/aa/wallhaven-imp-one.jpg", "resolution" => "1920x1080"},
      {"id" => "imp-two", "path" => "https://w.wallhaven.cc/full/bb/wallhaven-imp-two.jpg", "resolution" => "3840x2160"},
      {"id" => "imp-missing", "path" => File.join(dir, "gone.jpg")},
      {"name" => "no-path"},
    ].to_json)

    first = AetherImport.run(favorites)
    first[0].should eq 2 # two wallhaven entries queued
    first[2].should eq 2 # the missing local file and the entry without a path

    queued = Db.conn.query_one("SELECT COUNT(*) FROM jobs WHERE status = 'queued'", as: Int64)
    queued.should eq 2

    # running the import again must not queue anything new
    second = AetherImport.run(favorites)
    second[0].should eq 0
    Db.conn.query_one("SELECT COUNT(*) FROM jobs WHERE status = 'queued'", as: Int64).should eq 2

    Store.favorite?("imp-one").should be_true
  end
end
