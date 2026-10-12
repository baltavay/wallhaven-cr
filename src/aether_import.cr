require "json"
require "./store"
require "./jobs"
require "./config"

# One-shot import of the favourites collected by the previous (Go) Aether app.
#
# `~/.config/aether/favorites.json` mixes two shapes:
#   * {"id": "...", "path": "https://w.wallhaven.cc/full/..", "resolution": ..}
#   * {"name": "wallhaven-xxxx.jpg", "path": "/home/me/Wallpapers/wallhaven-xxxx.jpg"}
# The first becomes a wallhaven wallpaper whose original is queued for
# download; the second is registered as a local import.
module AetherImport
  def self.available? : Bool
    File.exists?(Config::AETHER_FAVORITES)
  end

  # Returns {wallhaven_queued, local_queued, skipped}.
  def self.run(favorites_path : String = Config::AETHER_FAVORITES, verbose : Bool = false) : Tuple(Int32, Int32, Int32)
    return {0, 0, 0} unless File.exists?(favorites_path)
    entries = JSON.parse(File.read(favorites_path)).as_a
    wallhaven = 0
    local = 0
    skipped = 0
    already_queued = Jobs.pending_download_ids

    entries.each do |entry|
      id = entry["id"]?.try(&.as_s?)
      remote = entry["path"]?.try(&.as_s?)
      if id && remote && (remote.starts_with?("http://") || remote.starts_with?("https://"))
        next if Store.wallpaper(id).try(&.original_file)
        next if already_queued.includes?(id)
        w = Wallpaper.new(id, "wallhaven")
        w.url = remote
        w.page_url = entry["url"]?.try(&.as_s?)
        w.resolution = entry["resolution"]?.try(&.as_s?)
        w.is_favorite = 1_i64
        w.added_at = Db.now
        w.colors_json = entry["colors"]?.try(&.to_json)
        w.meta_json = entry.to_json
        Store.upsert_wallpaper(w)
        Jobs.download_wallpaper(id, remote, favorite: true)
        wallhaven += 1
      elsif path = entry["path"]?.try(&.as_s?)
        unless File.exists?(path)
          skipped += 1
          next
        end
        local_id = "local-#{Digest::SHA1.hexdigest(path)[0, 12]}"
        if Store.wallpaper(local_id).try(&.original_file)
          skipped += 1
          next
        end
        Jobs.import_local(path, favorite: true)
        local += 1
      else
        skipped += 1
      end
    end

    if verbose
      puts "aether import: #{wallhaven} wallhaven downloads queued, #{local} local imports queued, #{skipped} skipped"
    end
    {wallhaven, local, skipped}
  end
end
