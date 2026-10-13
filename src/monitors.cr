require "json"
require "digest/sha1"
require "process"
require "file_utils"
require "./config"
require "./spawn"
require "./atomic_file"

# Live monitor geometry from Hyprland.
#
# Cropped versions are rendered at the exact pixel size of a monitor so the
# compositor never has to scale a 16K source at login.
module Monitors
  record Monitor, name : String, width : Int32, height : Int32, scale : Float64,
    x : Int32, y : Int32, focused : Bool do
    def label : String
      "#{name} #{width}x#{height}"
    end

    # Pixel size the compositor actually needs (Hyprland reports logical size;
    # scale > 1 means the physical buffer is larger).
    def pixel_width : Int32
      (width * scale).round.to_i
    end

    def pixel_height : Int32
      (height * scale).round.to_i
    end
  end

  FALLBACK = Monitor.new("fallback", 1920, 1080, 1.0, 0, 0, true)

  def self.all : Array(Monitor)
    result = Spawn.run("hyprctl", ["monitors", "-j"])
    return [FALLBACK] unless result.success?
    JSON.parse(result.output).as_a.map do |m|
      Monitor.new(
        m["name"].as_s,
        m["width"].as_i,
        m["height"].as_i,
        m["scale"]?.try(&.as_f) || 1.0,
        m["x"]?.try(&.as_i) || 0,
        m["y"]?.try(&.as_i) || 0,
        m["focused"]?.try(&.as_bool) || false)
    end
  rescue
    [FALLBACK]
  end

  def self.primary : Monitor
    list = all
    list.find(&.focused) || list.first? || FALLBACK
  end
end

# Omarchy theme integration.
#
# `omarchy-theme-set` discloses the active theme in two places:
#
#   * `~/.config/omarchy/backgrounds/<theme>/` — the user's own per-theme
#     wallpapers. This is the first directory its background search looks in and
#     the one the active wallpaper comes from. It survives theme changes.
#   * `~/.local/state/omarchy/current/theme/backgrounds/` — a *staging* copy of
#     the theme, which `omarchy-theme-set` deletes and recreates (`rm -rf
#     "$CURRENT_THEME_PATH"; mv "$NEXT_THEME_PATH" "$CURRENT_THEME_PATH"`) every
#     time a theme is applied. Anything written there is lost on the next theme
#     set or switch.
#
# So a favourite belongs in the first directory. Writing to the staging copy was
# the bug: wallpapers appeared to be added and then vanished.
module Omarchy
  HOME = Config::HOME
  STATE = File.join(HOME, ".local", "state", "omarchy", "current")
  STAGED_THEME = File.join(STATE, "theme")
  USER_THEMES = File.join(HOME, ".config", "omarchy", "themes")

  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif .bmp]

  # One wallpaper in the theme, with just enough metadata for the Theme view to
  # render a thumbnail and a delete control.
  record BackgroundEntry, name : String, path : String, size : Int64, mtime : Int64, ours : Bool

  # Outcome of `add_background`.
  enum AddStatus
    Added
    AlreadyPresent
  end

  record AddResult, path : String, status : AddStatus do
    def added? : Bool
      status.added?
    end
  end

  def self.current_theme_name : String?
    path = File.join(STATE, "theme.name")
    File.exists?(path) ? File.read(path).strip.presence : nil
  end

  # Where the user's wallpapers for the active theme belong: searched first by
  # `omarchy-theme-set`, and not wiped by it. Falls back to the staging copy only
  # when the active theme name is unknown.
  def self.backgrounds_dir : String
    # Override for tests and non-standard layouts.
    if override = ENV["WALLHAVEN_CR_THEME_DIR"]?.presence
      FileUtils.mkdir_p(override)
      return override
    end
    name = current_theme_name
    dir = if name && !name.empty?
            File.join(HOME, ".config", "omarchy", "backgrounds", name)
          else
            File.join(STAGED_THEME, "backgrounds")
          end
    FileUtils.mkdir_p(dir)
    dir
  end

  # The staging copy, listed for reference in the Theme view.
  def self.staged_backgrounds_dir : String
    File.join(STAGED_THEME, "backgrounds")
  end

  def self.wallpapers_dir : String
    dir = File.join(HOME, "Wallpapers")
    FileUtils.mkdir_p(dir)
    dir
  end

  # Copy one file into the current theme's backgrounds directory.
  #
  # Identity is the file's content, not its name: `version_name` gives a stable
  # name per wallpaper version, and if that name is already taken the existing
  # file is compared byte-for-byte (size first, then SHA-1). The same version can
  # therefore never be added twice, while a *different* version under the same
  # name gets a numbered sibling instead of overwriting or duplicating.
  def self.add_background(src : String, name : String? = nil) : AddResult
    raise ArgumentError.new("no such file: #{src}") unless File.exists?(src)
    dest_dir = backgrounds_dir
    base = sanitize(name || File.basename(src))
    # `omarchy-theme-set` picks wallpapers with `-iname '*.jpg' -o ... '*.png'`,
    # so a file without an image extension is invisible to it: always keep the
    # source file's extension.
    if File.extname(base).empty?
      base = "#{base}#{File.extname(src).downcase}"
    end
    dest = File.join(dest_dir, base)
    if File.exists?(dest)
      return AddResult.new(dest, AddStatus::AlreadyPresent) if same_content?(src, dest)
      # Same name, different bytes: keep both — but first walk the numbered
      # siblings, because the same version may already be sitting in one of them.
      stem = File.basename(base, File.extname(base))
      ext = File.extname(base)
      i = 1
      loop do
        candidate = File.join(dest_dir, "#{stem}-#{i}#{ext}")
        unless File.exists?(candidate)
          dest = candidate
          break
        end
        return AddResult.new(candidate, AddStatus::AlreadyPresent) if same_content?(src, candidate)
        i += 1
      end
    end

    # The same version may also be there under a name this scheme did not
    # produce (older naming, or a file dropped in by hand). Compare by size
    # first, so only files that could match are ever read.
    if found = find_same_content(dest_dir, src)
      return AddResult.new(found, AddStatus::AlreadyPresent)
    end

    # Atomic copy: `omarchy-theme-set` picks wallpapers with `-iname '*.jpg'`, so a
    # half-copied file would be a broken wallpaper, and the temporary deliberately
    # has no image extension so the search ignores it too.
    AtomicFile.write(dest, suffix: ".part") { |tmp| File.copy(src, tmp) }
    AddResult.new(dest, AddStatus::Added)
  end

  # Delete every file in the theme folder whose content is `src`, and return the
  # paths removed.
  #
  # Identity is content, mirroring `add_background`, so this removes the copy the
  # app added *and* any duplicate sitting under a different name (an older naming
  # scheme, or a file dropped in by hand). The source in the library is untouched,
  # so the version can be added again.
  def self.remove_background(src : String) : Array(String)
    raise ArgumentError.new("no such file: #{src}") unless File.exists?(src)
    dir = backgrounds_dir
    return [] of String unless Dir.exists?(dir)

    size = File.size(src)
    digest = Digest::SHA1.hexdigest(File.read(src))
    removed = [] of String
    Dir.children(dir).each do |entry|
      next unless IMAGE_EXTENSIONS.includes?(File.extname(entry).downcase)
      path = File.join(dir, entry)
      next unless File.size(path) == size
      next unless Digest::SHA1.hexdigest(File.read(path)) == digest
      File.delete(path)
      removed << path
    end
    removed
  end

  # True when the app's own library holds a file with this content, i.e. the theme
  # copy could be added again. Used to warn before an irreversible delete.
  def self.library_copy?(src : String) : Bool
    return false unless File.exists?(src)
    size = File.size(src)
    digest = Digest::SHA1.hexdigest(File.read(src))
    [Config.originals_dir, Config.crops_dir].each do |dir|
      Dir.children(dir).each do |entry|
        path = File.join(dir, entry)
        next unless File.size(path) == size
        return true if Digest::SHA1.hexdigest(File.read(path)) == digest
      end
    end
    false
  rescue
    false
  end

  # Any file in *dir* whose content equals *src* (sizes must match first, which is
  # what keeps the hashing to at most a couple of files).
  def self.find_same_content(dir : String, src : String) : String?
    size = File.size(src)
    Dir.children(dir).each do |entry|
      next unless IMAGE_EXTENSIONS.includes?(File.extname(entry).downcase)
      candidate = File.join(dir, entry)
      next unless File.size(candidate) == size
      return candidate if Digest::SHA1.hexdigest(File.read(candidate)) == Digest::SHA1.hexdigest(File.read(src))
    end
    nil
  end

  # Stable name for a wallpaper version, so the same version always maps to the
  # same file: `wallhaven-<id>.<ext>` for the original, and
  # `wallhaven-<id>-crop<N>.<ext>` for its cropped versions.
  def self.version_name(stem : String, source : String, crop_index : Int64? = nil) : String
    name = crop_index ? "#{stem}-crop#{crop_index + 1}" : stem
    "#{name}#{File.extname(source).downcase}"
  end

  # Names currently sitting in the theme folder, for the UI's "already added"
  # state.
  def self.background_names : Set(String)
    dir = backgrounds_dir
    return Set(String).new unless Dir.exists?(dir)
    names = Set(String).new
    Dir.children(dir).each do |entry|
      names << entry if IMAGE_EXTENSIONS.includes?(File.extname(entry).downcase)
    end
    names
  end

  # Size first (cheap), then SHA-1 — exact, and only paid when a name clashes.
  def self.same_content?(a : String, b : String) : Bool
    return false unless File.size(a) == File.size(b)
    Digest::SHA1.hexdigest(File.read(a)) == Digest::SHA1.hexdigest(File.read(b))
  end

  # Both directories `omarchy-theme-set` draws from. The folder this app manages
  # comes first — those are the files you add and remove — then anything that only
  # exists in the staging copy.
  def self.backgrounds : Array(String)
    names_in(backgrounds_dir) + (names_in(staged_backgrounds_dir) - names_in(backgrounds_dir))
  end

  # Everything omarchy would consider a wallpaper for this theme. Files in the
  # folder this app manages come first (those are the removable ones), then
  # entries that only exist in the staging copy.
  def self.background_entries : Array(BackgroundEntry)
    ours = names_in(backgrounds_dir)
    entries = ours.map { |name| entry_for(name, backgrounds_dir, true) }
    entries + (names_in(staged_backgrounds_dir) - ours).map { |name| entry_for(name, staged_backgrounds_dir, false) }
  end

  private def self.entry_for(name : String, dir : String, ours : Bool) : BackgroundEntry
    path = File.join(dir, name)
    info = File.info(path)
    BackgroundEntry.new(name, path, info.size, info.modification_time.to_unix, ours)
  rescue
    # A file that vanished between listing and stat-ing still gets a row.
    BackgroundEntry.new(name, File.join(dir, name), 0_i64, 0_i64, ours)
  end

  private def self.names_in(dir : String) : Array(String)
    return [] of String unless Dir.exists?(dir)
    Dir.children(dir).select { |f| IMAGE_EXTENSIONS.includes?(File.extname(f).downcase) }.sort
  end

  def self.sanitize(name : String) : String
    name.gsub(/[^A-Za-z0-9._-]+/, "_").sub(/^_+/, "")
  end
end
