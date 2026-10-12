require "json"
require "process"
require "file_utils"
require "./config"
require "./spawn"

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
# `omarchy-theme-set` stages the active theme at
# `~/.local/state/omarchy/current/theme/`, and picks wallpapers from its
# `backgrounds/` directory. Adding a favourite to the current theme is therefore
# just a copy into that directory.
module Omarchy
  HOME = Config::HOME
  STATE = File.join(HOME, ".local", "state", "omarchy", "current")
  STAGED_THEME = File.join(STATE, "theme")
  USER_THEMES = File.join(HOME, ".config", "omarchy", "themes")

  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif .bmp]

  def self.current_theme_name : String?
    path = File.join(STATE, "theme.name")
    File.exists?(path) ? File.read(path).strip.presence : nil
  end

  # Directory `omarchy-theme-set` reads wallpapers from.
  def self.backgrounds_dir : String
    dir = File.join(STAGED_THEME, "backgrounds")
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.wallpapers_dir : String
    dir = File.join(HOME, "Wallpapers")
    FileUtils.mkdir_p(dir)
    dir
  end

  # Copy one file into the current theme's backgrounds directory.
  # Returns the destination path. Refuses to overwrite an existing file with
  # different content by disambiguating the name.
  def self.add_background(src : String, name : String? = nil) : String
    raise ArgumentError.new("no such file: #{src}") unless File.exists?(src)
    dest_dir = backgrounds_dir
    base = sanitize(name || File.basename(src))
    dest = File.join(dest_dir, base)
    if File.exists?(dest) && File.size(dest) != File.size(src)
      stem = File.basename(base, File.extname(base))
      ext = File.extname(base)
      i = 1
      while File.exists?(dest)
        dest = File.join(dest_dir, "#{stem}-#{i}#{ext}")
        i += 1
      end
    end
    File.copy(src, dest) unless File.exists?(dest)
    dest
  end

  def self.backgrounds : Array(String)
    dir = backgrounds_dir
    return [] of String unless Dir.exists?(dir)
    Dir.children(dir).select { |f| IMAGE_EXTENSIONS.includes?(File.extname(f).downcase) }.sort
  end

  def self.sanitize(name : String) : String
    name.gsub(/[^A-Za-z0-9._-]+/, "_").sub(/^_+/, "")
  end
end
