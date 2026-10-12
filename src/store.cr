require "json"
require "./db"

# A wallpaper record: one row per wallhaven result, or per imported local file.
#
# Column-typed properties are read straight from the result set by
# `DB::Serializable`; richer accessors are layered on top and marked ignored.
class Wallpaper
  include DB::Serializable

  property id : String
  property source : String
  property url : String?
  property page_url : String?
  property resolution : String?
  property category : String?
  property purity : String?
  property colors_json : String?
  property is_favorite : Int64 = 0
  property meta_json : String?
  property added_at : Int64 = 0

  @[DB::Field(ignore: true)]
  property files : Array(WallpaperFile) = [] of WallpaperFile
  @[DB::Field(ignore: true)]
  property thumb_path : String?

  def initialize(@id : String, @source : String = "wallhaven", @is_favorite : Int64 = 0)
  end

  def favorite? : Bool
    is_favorite == 1
  end

  def colors : Array(String)
    return [] of String unless raw = colors_json
    JSON.parse(raw).as_a.map(&.as_s) rescue [] of String
  end

  def meta : JSON::Any?
    return nil unless raw = meta_json
    JSON.parse(raw) rescue nil
  end

  # Small thumbnail URL as advertised by the wallhaven API.
  def remote_thumb : String?
    meta.try(&.["thumbs"]?).try(&.["small"]?).try(&.as_s?)
  end

  def original_file : WallpaperFile?
    files.find { |f| f.kind == "original" }
  end

  def crop_files : Array(WallpaperFile)
    files.select { |f| f.kind == "crop" }
  end

  def downloaded? : Bool
    original_file.try(&.exists?) || false
  end
end

# A physical image file backing a wallpaper: the downloaded original or one of
# its cropped/converted versions. Each version is an independent row and can be
# deleted on its own; the original is never removed implicitly.
class WallpaperFile
  include DB::Serializable

  property id : Int64 = 0
  property wallpaper_id : String
  property kind : String
  property path : String
  property width : Int64 = 0
  property height : Int64 = 0
  property file_size : Int64 = 0
  property crop_index : Int64?
  property params_json : String?
  property created_at : Int64 = 0

  @[DB::Field(ignore: true)]
  property thumb_path : String?

  def initialize(@wallpaper_id : String, @kind : String, @path : String,
                 @width : Int64 = 0, @height : Int64 = 0)
  end

  def params : JSON::Any?
    return nil unless raw = params_json
    JSON.parse(raw) rescue nil
  end

  def label : String
    kind == "original" ? "original #{width}x#{height}" : "crop #{(crop_index || 0) + 1} #{width}x#{height}"
  end

  def exists? : Bool
    File.exists?(path)
  end
end

# Persistence for wallpapers, their files and favourites.
module Store
  def self.upsert_wallpaper(w : Wallpaper) : Nil
    Db.conn.exec(
      "INSERT INTO wallpapers
        (id, source, url, page_url, resolution, category, purity, colors_json,
         is_favorite, meta_json, added_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
        source = excluded.source,
        url = COALESCE(excluded.url, wallpapers.url),
        page_url = COALESCE(excluded.page_url, wallpapers.page_url),
        resolution = COALESCE(excluded.resolution, wallpapers.resolution),
        category = COALESCE(excluded.category, wallpapers.category),
        purity = COALESCE(excluded.purity, wallpapers.purity),
        colors_json = COALESCE(excluded.colors_json, wallpapers.colors_json),
        meta_json = COALESCE(excluded.meta_json, wallpapers.meta_json)",
      w.id, w.source, w.url, w.page_url, w.resolution, w.category, w.purity,
      w.colors_json, w.is_favorite, w.meta_json, w.added_at == 0 ? Db.now : w.added_at)
  end

  def self.wallpaper(id : String) : Wallpaper?
    w = Db.conn.query_one?("SELECT * FROM wallpapers WHERE id = ?", id, as: Wallpaper)
    w.try { |x| load_files(x) }
  end

  def self.load_files(w : Wallpaper) : Wallpaper
    w.files = files_for(w.id)
    w.thumb_path = thumb_for(w.original_file.try(&.id) || 0_i64)
    w
  end

  def self.files_for(wallpaper_id : String) : Array(WallpaperFile)
    files = Db.conn.query_all(
      "SELECT * FROM files WHERE wallpaper_id = ? ORDER BY kind DESC, crop_index ASC, id ASC",
      wallpaper_id, as: WallpaperFile)
    files.each { |f| f.thumb_path = thumb_for(f.id) }
    files
  end

  def self.thumb_for(file_id : Int64) : String?
    return nil if file_id == 0
    path = File.join(Config.thumbs_dir, "#{file_id}.jpg")
    File.exists?(path) ? path : nil
  end

  def self.insert_file(f : WallpaperFile) : Int64
    Db.conn.exec(
      "INSERT INTO files
        (wallpaper_id, kind, path, width, height, file_size, crop_index, params_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      f.wallpaper_id, f.kind, f.path, f.width, f.height, f.file_size, f.crop_index,
      f.params_json, f.created_at == 0 ? Db.now : f.created_at)
    Db.conn.query_one("SELECT last_insert_rowid()", as: Int64)
  end

  def self.update_file_geometry(id : Int64, width : Int64, height : Int64, size : Int64) : Nil
    Db.conn.exec("UPDATE files SET width = ?, height = ?, file_size = ? WHERE id = ?",
      width, height, size, id)
  end

  def self.delete_file(id : Int64) : Nil
    Db.conn.exec("DELETE FROM files WHERE id = ?", id)
    thumb = File.join(Config.thumbs_dir, "#{id}.jpg")
    File.delete(thumb) if File.exists?(thumb)
  end

  def self.set_favorite(id : String, value : Bool) : Nil
    Db.conn.exec("UPDATE wallpapers SET is_favorite = ? WHERE id = ?", value ? 1_i64 : 0_i64, id)
  end

  def self.favorite?(id : String) : Bool
    Db.conn.query_one?("SELECT is_favorite FROM wallpapers WHERE id = ?", id, as: Int64) == 1_i64
  end

  # All favourite ids, for cheap per-frame membership tests in the UI.
  def self.favorite_ids : Set(String)
    ids = Set(String).new
    Db.conn.query_all("SELECT id FROM wallpapers WHERE is_favorite = 1") do |rs|
      ids << rs.read(String)
    end
    ids
  end

  def self.favorites(only_downloaded : Bool = false) : Array(Wallpaper)
    rows = Db.conn.query_all(
      "SELECT * FROM wallpapers WHERE is_favorite = 1 ORDER BY added_at DESC", as: Wallpaper)
    list = rows.map { |w| load_files(w) }
    only_downloaded ? list.select(&.downloaded?) : list
  end

  def self.all_files(kind : String? = nil) : Array(WallpaperFile)
    tiles =
      if kind
        Db.conn.query_all("SELECT * FROM files WHERE kind = ? ORDER BY id", kind, as: WallpaperFile)
      else
        Db.conn.query_all("SELECT * FROM files ORDER BY id", as: WallpaperFile)
      end
    tiles.each { |f| f.thumb_path = thumb_for(f.id) }
    tiles
  end

  def self.count_wallpapers : Int64
    Db.conn.query_one("SELECT COUNT(*) FROM wallpapers", as: Int64)
  end

  def self.count_favorites : Int64
    Db.conn.query_one("SELECT COUNT(*) FROM wallpapers WHERE is_favorite = 1", as: Int64)
  end

  def self.meta(key : String) : String?
    Db.conn.query_one?("SELECT value FROM meta WHERE key = ?", key, as: String)
  end

  def self.set_meta(key : String, value : String) : Nil
    Db.conn.exec("INSERT INTO meta(key, value) VALUES(?, ?)
                  ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
  end
end
