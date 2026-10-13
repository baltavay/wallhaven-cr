require "json"
require "file_utils"

# Application configuration and on-disk layout.
#
# Everything the app owns lives under a single data directory:
#
#   ~/.local/share/wallhaven-cr/
#     wallhaven.db                  SQLite database
#     originals/<id>.<ext>          downloaded / imported original wallpapers
#     crops/<id>_<W>x<H>_<n>.<ext>  cropped + converted versions
#     thumbs/<key>.jpg              grid thumbnails (key = file row key)
#
# `thumb_key` is the database primary key of the `files` row, so an original and
# each of its cropped versions get their own thumbnail.
module Config
  HOME = ENV["HOME"]? || raise "HOME is not set"

  CONFIG_DIR  = File.join(HOME, ".config", "wallhaven-cr")
  CONFIG_FILE = File.join(CONFIG_DIR, "config.json")

  # Where the previous (Go) Aether app kept its wallhaven settings. Used once to
  # seed the API key so the user does not have to paste it again.
  AETHER_WALLHAVEN_CONFIG = File.join(HOME, ".config", "aether", "wallhaven.json")
  AETHER_FAVORITES        = File.join(HOME, ".config", "aether", "favorites.json")

  @@data_dir : String?

  def self.data_dir : String
    @@data_dir ||= begin
      dir = ENV["WALLHAVEN_CR_DATA"]? ||
            File.join(HOME, ".local", "share", "wallhaven-cr")
      FileUtils.mkdir_p(dir)
      dir
    end
  end

  def self.originals_dir : String
    dir = File.join(data_dir, "originals")
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.crops_dir : String
    dir = File.join(data_dir, "crops")
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.thumbs_dir : String
    dir = File.join(data_dir, "thumbs")
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.db_path : String
    File.join(data_dir, "wallhaven.db")
  end

  # Whole-image ("fit") thumbnails: ~1.5x the widest card, so tiles stay crisp when
  # scaled down through mipmaps.
  FIT_THUMB_SIZE = 448

  def self.thumb_cache_dir : String
    dir = File.join(thumbs_dir, "cache")
    FileUtils.mkdir_p(dir)
    dir
  end

  # Cache key for a wallpaper version's whole-image thumbnail. Stable for a given
  # version, so re-adding or re-downloading produces a new entry.
  def self.fit_thumb_key(wallpaper_id : String, file_id : Int64?) : String
    "favfit-#{wallpaper_id}-#{file_id || 0}"
  end

  # Where a cache key lives on disk (keys can contain characters that need hiding,
  # e.g. file names from the theme folder).
  def self.thumb_cache_path(key : String) : String
    File.join(thumb_cache_dir, "#{key.gsub(/[^A-Za-z0-9._-]+/, "_")}.jpg")
  end

  # Load settings, creating the file on first run.
  def self.load : Settings
    FileUtils.mkdir_p(CONFIG_DIR)
    if File.exists?(CONFIG_FILE)
      Settings.from_json(File.read(CONFIG_FILE))
    else
      settings = Settings.new
      settings.api_key = seed_api_key
      save(settings)
      settings
    end
  rescue JSON::ParseException | KeyError
    Settings.new.tap { |s| s.api_key = seed_api_key }
  end

  def self.save(settings : Settings) : Nil
    FileUtils.mkdir_p(CONFIG_DIR)
    File.write(CONFIG_FILE, settings.to_pretty_json)
  end

  def self.seed_api_key : String?
    return nil unless File.exists?(AETHER_WALLHAVEN_CONFIG)
    JSON.parse(File.read(AETHER_WALLHAVEN_CONFIG))["apiKey"]?.try(&.as_s?)
  rescue
    nil
  end
end

# Persisted user settings (config.json).
class Settings
  include JSON::Serializable

  # Wallhaven API key. Required for NSFW purity and the favourites endpoint.
  property api_key : String? = nil

  # Last used search filters, restored on launch.
  property query : String = ""
  property categories : String = "111"   # general / anime / people bitmask
  property purity : String = "100"       # sfw / sketchy / nsfw bitmask
  property sorting : String = "date_added"
  property order : String = "asc"
  property at_least : String = ""        # e.g. "1920x1080"
  property resolutions : String = ""     # comma separated exact resolutions
  property ratios : String = ""          # landscape | portrait | WxH
  property colors : String = ""          # hex without '#'

  # Number of result pages fetched and merged per search.
  property pages_per_search : Int32 = 1

  # Where the Favourites grid was scrolled to, so it is restored on the next run.
  property favorites_scroll : Float32 = 0_f32

  def initialize
  end
end
