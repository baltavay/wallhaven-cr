require "process"
require "file_utils"
require "./config"
require "./spawn"
require "./atomic_file"

# Image processing, delegated to an external tool.
#
# Backends, in order of preference:
#
#   * libvips (`vips`, `vipsheader`) — ~2x faster than ImageMagick on 8K
#     sources and, because it streams with shrink-on-load, it peaks at ~60-120 MB
#     where ImageMagick peaked at 550-710 MB per image. Measured on 5500x8000
#     JPEGs: thumb 256 0.31s/61MB vs 0.60s/546MB, preview 2048 0.56s/119MB vs
#     0.80s/682MB, crop 1920x1080 0.34s/110MB vs 0.76s/710MB.
#   * ImageMagick 7 (`magick`) or 6 (`convert`) — the portable fallback, present
#     on nearly every Linux box; libvips is not guaranteed outside Arch.
#
# Both are driven as subprocesses (never in-process) so an 8K decode cannot
# grow this process, and always through `Spawn` (posix_spawn) because forking a
# process with a live GL context is unsafe — see src/spawn.cr.
module ImageOps
  class Error < Exception
  end

  enum Backend
    Vips
    ImageMagick
  end

  # JPEG quality per use: thumbnails/previews are small, crops are the wallpaper.
  PREVIEW_QUALITY = 88
  CROP_QUALITY    = 92

  @@backend : Backend?
  @@binary : String?
  @@counter = Atomic(Int32).new(0)

  # Which backend is in use ("vips" or "magick"/"convert").
  def self.backend_name : String
    select_backend
    case backend
    when Backend::Vips then "vips"
    else                     File.basename(@@binary.not_nil!)
    end
  end

  def self.backend : Backend
    select_backend
    @@backend.not_nil!
  end

  def self.vips? : Bool
    backend.vips?
  end

  def self.available? : Bool
    select_backend
    true
  rescue Error
    false
  end

  # `WALLHAVEN_CR_IMAGE_TOOL=vips|magick|convert` forces a backend; otherwise
  # libvips is preferred when installed.
  private def self.preferred : String?
    ENV["WALLHAVEN_CR_IMAGE_TOOL"]?.presence
  end

  private def self.select_backend : Nil
    return if @@backend
    if (want = preferred) && (found = Process.find_executable(want))
      @@binary = found
      @@backend = want == "vips" ? Backend::Vips : Backend::ImageMagick
      return
    end
    if found = Process.find_executable("vips")
      @@binary = found
      @@backend = Backend::Vips
    elsif found = (Process.find_executable("magick") || Process.find_executable("convert"))
      @@binary = found
      @@backend = Backend::ImageMagick
    else
      raise Error.new("no image tool found: install libvips (vips) or ImageMagick (magick)")
    end
  end

  # Pixel dimensions of an image file, corrected for EXIF orientation.
  def self.identify(path : String) : {Int64, Int64}
    width, height, orientation =
      if vips?
        vips_size(path)
      else
        im_size(path)
      end
    # 5..8 mean "rotated a quarter turn": the visible image is the transpose.
    if orientation && (5..8).includes?(orientation)
      {height, width}
    else
      {width, height}
    end
  rescue ex : Error
    raise Error.new("cannot read #{File.basename(path)}: #{ex.message}")
  end

  # Downscaled preview used by the crop editor (never upscales).
  def self.preview(src : String, dst : String, max : Int32 = 2048) : Nil
    mkdir(dst)
    AtomicFile.write(dst) do |target|
      if vips?
        run(@@binary.not_nil!, ["thumbnail", src, with_quality(target, PREVIEW_QUALITY), max.to_s, "--size", "down"])
      else
        run(@@binary.not_nil!, [src, "-auto-orient", "-resize", "#{max}x#{max}>",
          "-strip", "-quality", PREVIEW_QUALITY.to_s, target])
      end
    end
  end

  # Cut `rect` (source pixels) out of `src` and scale it to exactly
  # `out_w`x`out_h` — the monitor's pixel size for a cropped wallpaper version.
  def self.crop_resize(src : String, dst : String, rect : {Int64, Int64, Int64, Int64},
                       out_w : Int32, out_h : Int32, quality : Int32 = CROP_QUALITY) : Nil
    x, y, w, h = rect
    w = 1_i64 if w < 1
    h = 1_i64 if h < 1
    raise Error.new("unsupported output format #{File.extname(dst)}") unless encodable?(dst)
    mkdir(dst)

    if vips?
      # libvips cannot crop and resize in one invocation; the intermediate is its
      # native format, written next to the output (real disk, not /tmp which is
      # tmpfs here) and removed immediately.
      # The suffix must be `.v`: libvips picks the format from it.
      vtmp = File.join(File.dirname(dst),
        ".#{File.basename(dst, File.extname(dst))}.#{Process.pid}.#{@@counter.add(1)}.v")
      begin
        run(@@binary.not_nil!, ["crop", src, vtmp, x.to_s, y.to_s, w.to_s, h.to_s])
        AtomicFile.write(dst) do |target|
          run(@@binary.not_nil!, ["resize", vtmp, with_quality(target, quality),
            (out_w.to_f64 / w).to_s, "--vscale", (out_h.to_f64 / h).to_s])
        end
      ensure
        File.delete(vtmp) if File.exists?(vtmp)
      end
    else
      AtomicFile.write(dst) do |target|
        run(@@binary.not_nil!, [src, "-auto-orient", "-crop", "#{w}x#{h}+#{x}+#{y}", "+repage",
          "-resize", "#{out_w}x#{out_h}!", "-strip", "-quality", quality.to_s, target])
      end
    end
  end

  # ---- backend specifics

  private def self.vips_size(path : String) : {Int64, Int64, Int32?}
    output = run("vipsheader", ["-a", path])
    width = field(output, "width").try(&.to_i64?)
    height = field(output, "height").try(&.to_i64?)
    orientation = field(output, "orientation") || field(output, "exif-ifd0-Orientation")
    raise Error.new("no dimensions in vipsheader output") unless width && height
    {width, height, orientation.try(&.to_i?)}
  end

  private def self.im_size(path : String) : {Int64, Int64, Int32?}
    output = run(@@binary.not_nil!, ["identify", "-format", "%w %h", path])
    parts = output.split(' ')
    raise Error.new("unexpected identify output #{output.inspect}") unless parts.size >= 2
    {parts[0].to_i64, parts[1].to_i64, nil}
  end

  # Parse a `field: value` line from `vipsheader -a`.
  private def self.field(output : String, name : String) : String?
    output.each_line do |line|
      if line.starts_with?("#{name}:")
        return line[(name.size + 1)..].strip
      end
    end
    nil
  end

  # libvips takes the save options as a `[Q=88]` suffix on the output filename.
  private def self.with_quality(path : String, quality : Int32) : String
    "#{path}[Q=#{quality}]"
  end

  private def self.mkdir(dst : String) : Nil
    FileUtils.mkdir_p(File.dirname(dst))
  end

  # True when the backend can write the extension directly.
  private def self.encodable?(path : String) : Bool
    %w[.jpg .jpeg .png .webp .avif .tiff .bmp].includes?(File.extname(path).downcase)
  end

  private def self.run(executable : String, args : Array(String)) : String
    result = Spawn.run(executable, args)
    raise Error.new(result.message) unless result.success?
    result.output.strip
  end
end
