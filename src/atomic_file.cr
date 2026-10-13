require "file_utils"

# Write a file so that a reader never sees it half-written.
#
# The content is built in a temporary file in the destination's own directory and
# then renamed into place; `rename(2)` within a directory is atomic, so the
# destination either does not exist or is complete.
#
# This matters here because other processes and threads read these files while
# they are being produced: the UI loads thumbnails as textures (a partially
# written 2048 px preview is ~230 ms of a file that decodes with pieces missing,
# and the broken texture is then cached), and `omarchy-theme-set` scans the theme
# folder for wallpapers with `find -iname '*.jpg'`.
module AtomicFile
  @@counter = Atomic(Int32).new(0)

  # `suffix` is what the temporary file ends with. Keep the default (the
  # destination's own extension) for tools that infer the output format from the
  # filename — libvips and ImageMagick both do. Pass something else (e.g. ".part")
  # when a directory scan must not mistake the temporary for a real image.
  def self.write(destination : String, suffix : String? = nil, &block : String -> Nil) : Nil
    directory = File.dirname(destination)
    FileUtils.mkdir_p(directory)
    stem = File.basename(destination, File.extname(destination))
    temporary = File.join(directory,
      ".#{stem}.#{Process.pid}.#{@@counter.add(1)}#{suffix || File.extname(destination)}")
    begin
      block.call(temporary)
      File.rename(temporary, destination)
    ensure
      File.delete(temporary) if File.exists?(temporary)
    end
  end

  # Temporaries left behind by a killed process. `match_hidden: true` is required:
  # temporaries start with a dot, and `Dir.glob` skips dotfiles by default.
  def self.stale(directory : String) : Array(String)
    return [] of String unless Dir.exists?(directory)
    Dir.glob(File.join(directory, "**", "*.part*"),
      match: File::MatchOptions.glob_default | File::MatchOptions::DotFiles)
  end
end
