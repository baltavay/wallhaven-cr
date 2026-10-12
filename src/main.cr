require "digest/sha1"
require "json"
require "./config"
require "./db"
require "./store"
require "./wallhaven"
require "./jobs"
require "./images"
require "./monitors"
require "./aether_import"
require "./ui"

# Wallhaven wallpaper manager for Omarchy.
#
# Default (no arguments) opens the raylib window. Everything the UI does is also
# reachable headlessly, which is what the smoke checks exercise.
module App
  VERSION = "0.1.0"

  def self.run(argv : Array(String)) : Int32
    enable_core_dumps
    case argv.first?
    when nil
      Db.setup
      Ui.run
    when "--capture"
      Db.setup
      capture(argv[1..])
    when "--help", "-h"
      puts usage
    when "--version"
      puts "wallhaven-cr #{VERSION} (#{built_at})"
    when "--import-aether"
      # Queues only: the worker (GUI or --drain) is what processes the queue, so
      # the app can be opened and watched while it fills up.
      Db.setup
      AetherImport.run(verbose: true)
      stats
    when "--import-local"
      Db.setup
      path = argv[1]?
      abort "usage: wallhaven-cr --import-local PATH" unless path
      queue_only(Jobs.enqueue(Jobs::IMPORT_LOCAL, {"path" => File.expand_path(path), "favorite" => true}))
    when "--search"
      Db.setup
      search(argv[1..])
    when "--monitors"
      Monitors.all.each { |m| puts "#{m.name} #{m.width}x#{m.height} scale=#{m.scale} focused=#{m.focused}" }
    when "--stats"
      Db.setup
      stats
    when "--drain"
      Db.setup
      drain(verbose: true)
      stats
    when "--download"
      Db.setup
      download_from_cli(argv[1..])
    when "--convert"
      Db.setup
      version_from_cli(argv[1..])
    else
      abort usage
    end
    0
  rescue e
    STDERR.puts "wallhaven-cr: #{e.message}"
    1
  end

  # Build stamp of the running binary: makes "am I running the fixed build?"
  # answerable without guessing.
  def self.built_at : String
    path = Process.executable_path || PROGRAM_NAME
    File.info(path).modification_time.to_local.to_s("%Y-%m-%d %H:%M:%S")
  rescue
    "unknown"
  end

  # Crystal's fatal-signal handler prints a backtrace and `_exit(1)`s, so a
  # segfault leaves no core. With WALLHAVEN_CR_CORE=1 the default handlers are
  # restored, letting the kernel dump a core that can be inspected afterwards.
  def self.enable_core_dumps : Nil
    return unless ENV["WALLHAVEN_CR_CORE"]? == "1"
    Signal::SEGV.reset
    Signal::BUS.reset
    Signal::ILL.reset
    Signal::ABRT.reset
  end

  def self.usage : String
    <<-USAGE
    wallhaven-cr #{VERSION} — wallhaven.cc wallpaper manager for Omarchy

    Usage:
      wallhaven-cr                       open the GUI
      wallhaven-cr --search [OPTIONS]    search wallhaven and print JSON
      wallhaven-cr --import-aether       queue the old Aether favourites (no drain)
      wallhaven-cr --import-local PATH   add a local image to favourites
      wallhaven-cr --download ID         queue a wallpaper download by id
      wallhaven-cr --convert ID          queue a monitor-sized version (centred crop)
      wallhaven-cr --drain               run queued background jobs to completion
      wallhaven-cr --monitors            list Hyprland monitors
      wallhaven-cr --stats               show database and job counts
      wallhaven-cr --capture PATH        render one frame of the UI to a PNG and exit
                                         (--frames N, --view browse|favourites|editor|queue|theme)

    Search options:
      -q, --query TEXT        search terms
      -c, --categories MASK   100 general, 010 anime, 001 people, 111 all
      -p, --purity MASK       100 sfw, 010 sketchy, 001 nsfw
      -s, --sorting KIND      date_added|relevance|random|views|favorites|toplist
      -o, --order DIR         desc|asc
          --atleast RES       minimum resolution, e.g. 1920x1080
          --resolutions RES   comma separated exact resolutions
          --ratios RATIOS     landscape|portrait|16x9|...
          --colors HEX        hex colour without '#'
          --top-range RANGE   1d|3d|1w|1M|3M|6M|1y
          --page N            page number (default 1)
          --pages N           fetch and merge N pages
    USAGE
  end

  def self.search(args : Array(String)) : Nil
    settings = Config.load
    json_out = args.includes?("--json")
    q = settings.query
    categories = settings.categories
    purity = settings.purity
    sorting = settings.sorting
    order = settings.order
    at_least = settings.at_least
    resolutions = settings.resolutions
    ratios = settings.ratios
    colors = settings.colors
    top_range = ""
    page = 1
    pages = settings.pages_per_search

    i = 0
    while i < args.size
      arg = args[i]
      value = args[i + 1]?
      case arg
      when "-q", "--query"       then q = need(arg, value); i += 1
      when "-c", "--categories"  then categories = need(arg, value); i += 1
      when "-p", "--purity"      then purity = need(arg, value); i += 1
      when "-s", "--sorting"     then sorting = need(arg, value); i += 1
      when "-o", "--order"       then order = need(arg, value); i += 1
      when "--atleast"           then at_least = need(arg, value); i += 1
      when "--resolutions"       then resolutions = need(arg, value); i += 1
      when "--ratios"            then ratios = need(arg, value); i += 1
      when "--colors"            then colors = need(arg, value); i += 1
      when "--top-range"         then top_range = need(arg, value); i += 1
      when "--page"              then page = need(arg, value).to_i; i += 1
      when "--pages"             then pages = need(arg, value).to_i; i += 1
      when "--json"              # flag, handled above
      else
        abort "unknown search option: #{arg}"
      end
      i += 1
    end

    query = Wallhaven::Query.new(q, categories, purity, sorting, order, top_range,
      at_least, resolutions, ratios, colors, page, "")
    client = Wallhaven.new(settings.api_key)
    result = client.search_pages(query, pages)
    # Persist so the GUI sees them immediately.
    result.data.each { |w| Store.upsert_wallpaper(w) }

    if json_out
      puts(JSON.build do |json|
        json.object do
          json.field "page", result.page
          json.field "last_page", result.last_page
          json.field "total", result.total
          json.field "count", result.data.size
          json.field "data" do
            json.array do
              result.data.each do |w|
                json.object do
                  json.field "id", w.id
                  json.field "resolution", w.resolution
                  json.field "category", w.category
                  json.field "purity", w.purity
                  json.field "url", w.url
                  json.field "thumb", w.remote_thumb
                  json.field "colors", w.colors
                end
              end
            end
          end
        end
      end)
    else
      puts "#{result.data.size} results (page #{result.page}/#{result.last_page}, #{result.total} total)"
      result.data.each do |w|
        puts "  #{w.id}  #{w.resolution}  #{w.purity}/#{w.category}  #{w.url}"
      end
    end
  ensure
    client.try(&.close)
  end

  private def self.need(flag : String, value : String?) : String
    abort "#{flag} requires a value" unless value
    value
  end

  # Process the queue synchronously (used by the CLI and smoke checks).
  def self.drain(verbose : Bool = false, timeout : Time::Span = 10.minutes) : Nil
    Jobs.requeue_stale
    started = Time.instant
    while (Time.instant - started) < timeout
      counts = Jobs.counts
      break if counts["queued"] == 0 && counts["running"] == 0
      unless Jobs.drain_once
        sleep 0.2.seconds
      end
    end
    failed = Jobs.failed
    unless failed.empty?
      STDERR.puts "#{failed.size} failed job(s):"
      failed.each { |j| STDERR.puts "  ##{j.id} #{j.kind}: #{j.error}" }
    end
  end

  # Fetch a wallpaper by id (from the database, or straight from the API) and
  # queue its download. Headless equivalent of the UI's "Download original".
  def self.download_from_cli(args : Array(String)) : Nil
    id = args.first?
    abort "usage: wallhaven-cr --download ID [--favourite]" unless id
    wallpaper = Store.wallpaper(id)
    unless wallpaper
      client = Wallhaven.new(Config.load.api_key)
      begin
        wallpaper = client.wallpaper(id)
      ensure
        client.close
      end
      abort "unknown wallpaper #{id}" unless wallpaper
      Store.upsert_wallpaper(wallpaper.not_nil!)
    end
    url = wallpaper.not_nil!.url
    abort "#{id} has no source url" unless url
    queue_only(Jobs.download_wallpaper(id, url, favorite: args.includes?("--favourite")))
  end

  # Convert a downloaded wallpaper into a monitor-sized version, centred at the
  # largest possible crop. Headless equivalent of "Create version" in the editor.
  def self.version_from_cli(args : Array(String)) : Nil
    id = args.first?
    abort "usage: wallhaven-cr --convert ID [--monitor NAME]" unless id
    wallpaper = Store.wallpaper(id)
    abort "unknown wallpaper #{id}" unless wallpaper
    source = wallpaper.original_file
    abort "#{id} has no downloaded original — run --download #{id} first" unless source
    abort "original file is missing: #{source.path}" unless File.exists?(source.path)

    wanted = args.each_with_index.find { |a, _| a == "--monitor" }.try { |(_, i)| args[i + 1]? }
    monitor = Monitors.all.find { |m| m.name == wanted } || Monitors.primary
    out_w = monitor.pixel_width
    out_h = monitor.pixel_height

    # largest centred crop with the monitor's aspect ratio
    src_w = source.width
    src_h = source.height
    ratio = out_w.to_f64 / out_h.to_f64
    if src_w.to_f64 / src_h.to_f64 > ratio
      w = (src_h.to_f64 * ratio).round.to_i64
      h = src_h
    else
      w = src_w
      h = (src_w.to_f64 / ratio).round.to_i64
    end
    x = (src_w - w) // 2
    y = (src_h - h) // 2

    queue_only(Jobs.crop(id, source.id, x, y, w, h, out_w, out_h, "#{monitor.name} #{out_w}x#{out_h}"))
  end

  # Render the UI once into a PNG. Independent of the compositor, so it also
  # works over SSH or when the window manager does not composite the window.
  def self.capture(args : Array(String)) : Nil
    path = args.first?
    abort "usage: wallhaven-cr --capture PATH [--frames N] [--view NAME]" unless path
    frames = args.each_with_index.find { |a, _| a == "--frames" }.try { |(_, i)| args[i + 1]?.try(&.to_i) } || 60
    view = args.each_with_index.find { |a, _| a == "--view" }.try { |(_, i)| args[i + 1]? }
    Ui.run(File.expand_path(path), frames, view)
  end

  # Enqueue-and-report. None of the queueing verbs drain: `--drain` does that, and
  # the GUI drains on its own while you watch it. Draining here would also run
  # whatever else happened to be queued, which is not what "download this one"
  # means.
  def self.queue_only(job_id : Int64) : Nil
    counts = Jobs.counts
    puts "job ##{job_id} queued (#{counts["queued"]} queued) — run `--drain` or open the GUI to process it"
    stats
  end

  def self.stats : Nil
    counts = Jobs.counts
    puts "wallpapers: #{Store.count_wallpapers} (#{Store.count_favorites} favourites)"
    puts "files:      #{Store.all_files.size}"
    puts "jobs:       #{counts.map { |k, v| "#{k}=#{v}" }.join(" ")}"
    originals = Store.all_files("original").size
    crops = Store.all_files("crop").size
    puts "originals:  #{originals}   crops: #{crops}"
    puts "monitors:   #{Monitors.all.map(&.label).join(", ")}"
    puts "theme:      #{Omarchy.current_theme_name || "(none)"}"
    # Heap diagnostics: this app keeps image work out of process, so the Crystal
    # heap stays small and there is nothing for Boehm to hand back to the OS.
    stats = GC.stats
    printf("heap:       %.1f MB used of %.1f MB (free %.1f MB, unmapped %.1f MB)\n",
      (stats.heap_size - stats.free_bytes) / 1048576.0, stats.heap_size / 1048576.0,
      stats.free_bytes / 1048576.0, stats.unmapped_bytes / 1048576.0)
  end
end

exit App.run(ARGV)
