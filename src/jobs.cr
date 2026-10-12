require "http/client"
require "json"
require "uri"
require "digest/sha1"
require "./db"
require "./store"
require "./images"
require "./config"
require "./monitors"

# Background work queue, drained by one dedicated worker thread.
#
# Same shape as `binance_bot_cr`: durable jobs live in a SQLite table, the
# worker claims the oldest queued row, executes it, and records the outcome.
# Downloads and image processing therefore never block the UI thread, and a job
# survives a crash of the window.
module Jobs
  # A row of the `jobs` table.
  class Record
    include DB::Serializable

    property id : Int64
    property kind : String
    property payload : String
    property status : String
    property attempts : Int64 = 0
    property error : String?
    property note : String?
    property result : String?
    property created_at : Int64 = 0
    property started_at : Int64?
    property finished_at : Int64?

    def initialize(@id : Int64, @kind : String, @payload : String, @status : String)
    end

    def payload_json : JSON::Any
      JSON.parse(payload)
    end
  end

  # Kind names.
  DOWNLOAD     = "download"
  THUMBNAIL    = "thumbnail"
  CROP         = "crop"
  IMPORT_LOCAL = "import_local"

  LOG_LIMIT = 200
  LOG_MUTEX = Mutex.new
  LOG       = [] of String

  @@running = false
  @@stopping = false
  @@context : Fiber::ExecutionContext::Isolated?

  # ---- public API -----------------------------------------------------------

  def self.enqueue(kind : String, payload : Hash | JSON::Any | String) : Int64
    json = payload.is_a?(String) ? payload : payload.to_json
    Db.conn.exec("INSERT INTO jobs(kind, payload, status, created_at) VALUES(?, ?, 'queued', ?)",
      kind, json, Db.now)
    Db.conn.query_one("SELECT last_insert_rowid()", as: Int64)
  end

  # Queue a download of one wallhaven wallpaper; a thumbnail job follows once
  # the file lands.
  def self.download_wallpaper(id : String, url : String, favorite : Bool = false) : Int64
    enqueue(DOWNLOAD, {"wallpaper_id" => id, "url" => url, "favorite" => favorite})
  end

  def self.thumbnail(file_id : Int64) : Int64
    enqueue(THUMBNAIL, {"file_id" => file_id})
  end

  def self.crop(wallpaper_id : String, source_file_id : Int64,
                x : Int64, y : Int64, w : Int64, h : Int64,
                out_w : Int32, out_h : Int32, target : String) : Int64
    enqueue(CROP, {
      "wallpaper_id" => wallpaper_id, "source_file_id" => source_file_id,
      "x" => x, "y" => y, "w" => w, "h" => h,
      "out_w" => out_w, "out_h" => out_h, "target" => target,
    })
  end

  def self.import_local(path : String, favorite : Bool = true) : Int64
    enqueue(IMPORT_LOCAL, {"path" => path, "favorite" => favorite})
  end

  def self.counts : Hash(String, Int64)
    result = {"queued" => 0_i64, "running" => 0_i64, "succeeded" => 0_i64, "failed" => 0_i64}
    Db.conn.query_all("SELECT status, COUNT(*) AS n FROM jobs GROUP BY status") do |rs|
      result[rs.read(String)] = rs.read(Int64)
    end
    result
  end

  # Wallpaper ids that already have a download queued or running, so an import
  # cannot queue the same wallpaper twice.
  def self.pending_download_ids : Set(String)
    ids = Set(String).new
    Db.conn.query_all("SELECT payload FROM jobs WHERE kind = ? AND status IN ('queued', 'running')", DOWNLOAD) do |rs|
      begin
        ids << JSON.parse(rs.read(String))["wallpaper_id"].as_s
      rescue
      end
    end
    ids
  end

  def self.recent(limit : Int32 = 20) : Array(Record)
    Db.conn.query_all("SELECT * FROM jobs ORDER BY id DESC LIMIT #{limit}", as: Record)
  end

  def self.failed(limit : Int32 = 20) : Array(Record)
    Db.conn.query_all("SELECT * FROM jobs WHERE status = 'failed' ORDER BY id DESC LIMIT #{limit}", as: Record)
  end

  def self.log(message : String) : Nil
    LOG_MUTEX.synchronize do
      LOG << "#{Time.local.to_s("%H:%M:%S")} #{message}"
      while LOG.size > LOG_LIMIT
        LOG.shift
      end
    end
  end

  def self.log_lines : Array(String)
    LOG_MUTEX.synchronize { LOG.dup }
  end

  # ---- worker ---------------------------------------------------------------

  # Run one queued job on the calling thread. Used by the CLI `--drain` mode
  # and by the smoke checks; returns false when nothing is queued.
  def self.drain_once : Bool
    job = claim
    return false unless job
    run(job)
    true
  rescue e
    log "claim failed: #{e.message}"
    false
  end

  # A process killed mid-job leaves rows in 'running' forever, which would block
  # the single worker slot. Requeue them on start; give up after MAX_ATTEMPTS.
  MAX_ATTEMPTS = 3

  def self.requeue_stale : Int32
    # A killed download leaves a `.part` file behind; the job is requeued, so
    # the leftover would only waste disk space.
    Dir.glob(File.join(Config.originals_dir, "*.part")).each do |stale|
      File.delete(stale) if File.exists?(stale)
    end

    n = Db.conn.exec("UPDATE jobs SET status = 'queued' WHERE status = 'running' AND attempts < ?", MAX_ATTEMPTS).rows_affected
    m = Db.conn.exec("UPDATE jobs SET status = 'failed', error = COALESCE(error, 'abandoned: too many attempts'), finished_at = ? WHERE status = 'running'", Db.now).rows_affected
    log "requeued #{n} stale job(s), abandoned #{m}" if n > 0 || m > 0
    n.to_i32
  end

  def self.start : Nil
    return if @@running
    @@running = true
    @@stopping = false
    # A dedicated execution context: `Thread.new` gives a thread without an
    # event loop, and any file/socket IO (downloads, ImageMagick, Time.local)
    # would raise "Thread#execution_context cannot be nil" there.
    @@context = Fiber::ExecutionContext::Isolated.new("wh-jobs") do
      Thread.name = "wh-jobs"
      Db.setup
      requeue_stale
      log "worker started"
      until @@stopping
        begin
          job = claim
          if job
            run(job)
          else
            sleep 0.25.seconds
          end
        rescue e
          log "worker error: #{e.message}"
          sleep 0.5.seconds
        end
      end
      log "worker stopped"
    end
  end

  def self.stop : Nil
    @@stopping = true
    @@context.try(&.join)
    @@running = false
  end

  # Claim the oldest queued job atomically.
  #
  # Order of service: things the user just asked for (a crop, a file they added)
  # first, then thumbnails, then downloads. Plain FIFO would put every thumbnail
  # behind every download, so a fresh library would show an empty grid for the
  # whole download phase; this way each download is followed by its thumbnail and
  # the grid fills in as it goes.
  private def self.claim : Record?
    Db.conn.query_one?(
      "UPDATE jobs SET status = 'running', started_at = ?, attempts = attempts + 1
       WHERE id = (SELECT id FROM jobs WHERE status = 'queued'
                   ORDER BY CASE kind
                            WHEN 'crop' THEN 0
                            WHEN 'import_local' THEN 0
                            WHEN 'thumbnail' THEN 1
                            ELSE 2
                            END, id
                   LIMIT 1)
       RETURNING *", Db.now, as: Record)
  end

  private def self.run(job : Record) : Nil
    case job.kind
    when DOWNLOAD      then run_download(job)
    when THUMBNAIL     then run_thumbnail(job)
    when CROP          then run_crop(job)
    when IMPORT_LOCAL  then run_import_local(job)
    else
      raise "unknown job kind #{job.kind}"
    end
  rescue e
    Db.conn.exec("UPDATE jobs SET status = 'failed', error = ?, finished_at = ? WHERE id = ?",
      e.message, Db.now, job.id)
    log "#{job.kind} ##{job.id} failed: #{e.message}"
  end

  private def self.succeed(job : Record, result : String) : Nil
    Db.conn.exec("UPDATE jobs SET status = 'succeeded', result = ?, note = NULL, finished_at = ? WHERE id = ?",
      result, Db.now, job.id)
    log "#{job.kind} ##{job.id} done: #{result}"
  end

  private def self.note(job : Record, text : String) : Nil
    Db.conn.exec("UPDATE jobs SET note = ? WHERE id = ?", text, job.id)
  end

  private def self.run_download(job : Record) : Nil
    payload = job.payload_json
    wallpaper_id = payload["wallpaper_id"].as_s
    url = payload["url"].as_s

    wallpaper = Store.wallpaper(wallpaper_id)
    if wallpaper && wallpaper.original_file
      succeed(job, "already downloaded")
      return
    end

    ext = File.extname(URI.parse(url).path).presence || ".jpg"
    dest = File.join(Config.originals_dir, "#{wallpaper_id}#{ext}")
    note(job, "downloading #{File.basename(dest)}")
    bytes = http_download(url, dest, job)

    width, height = ImageOps.identify(dest)
    file = WallpaperFile.new(wallpaper_id, "original", dest, width, height)
    file.file_size = File.size(dest)
    file.created_at = Db.now
    file_id = Store.insert_file(file)

    if wallpaper
      if payload["favorite"]?.try(&.as_bool?)
        Store.set_favorite(wallpaper_id, true)
      end
      Store.upsert_wallpaper(wallpaper)
    end

    Jobs.thumbnail(file_id)
    succeed(job, "#{File.basename(dest)} (#{bytes // 1024} KiB)")
  end

  private def self.run_thumbnail(job : Record) : Nil
    file_id = job.payload_json["file_id"].as_i64
    file = Db.conn.query_one?("SELECT * FROM files WHERE id = ?", file_id, as: WallpaperFile)
    raise "file #{file_id} not found" unless file
    raise "source missing: #{file.path}" unless File.exists?(file.path)

    dest = File.join(Config.thumbs_dir, "#{file_id}.jpg")
    note(job, "thumbnail #{File.basename(file.path)}")
    ImageOps.thumbnail(file.path, dest)

    # Originals also get a bounded preview for the crop editor.
    if file.kind == "original"
      preview = File.join(Config.thumbs_dir, "preview-#{file_id}.jpg")
      ImageOps.preview(file.path, preview, 2048)
    end
    succeed(job, File.basename(dest))
  end

  private def self.run_crop(job : Record) : Nil
    p = job.payload_json
    wallpaper_id = p["wallpaper_id"].as_s
    source_id = p["source_file_id"].as_i64
    x = p["x"].as_i64
    y = p["y"].as_i64
    w = p["w"].as_i64
    h = p["h"].as_i64
    out_w = p["out_w"].as_i
    out_h = p["out_h"].as_i
    target = p["target"].as_s

    source = Db.conn.query_one?("SELECT * FROM files WHERE id = ?", source_id, as: WallpaperFile)
    raise "source file #{source_id} not found" unless source
    raise "source missing: #{source.path}" unless File.exists?(source.path)

    index = Db.conn.query_one(
      "SELECT COALESCE(MAX(crop_index), -1) + 1 FROM files WHERE wallpaper_id = ? AND kind = 'crop'",
      wallpaper_id, as: Int64)

    base = File.basename(source.path, File.extname(source.path))
    dest = File.join(Config.crops_dir, "#{base}_#{out_w}x#{out_h}_#{index}.jpg")
    note(job, "cropping to #{out_w}x#{out_h} (#{target})")
    ImageOps.crop_resize(source.path, dest, {x, y, w, h}, out_w, out_h)

    file = WallpaperFile.new(wallpaper_id, "crop", dest, out_w.to_i64, out_h.to_i64)
    file.file_size = File.size(dest)
    file.crop_index = index
    file.created_at = Db.now
    file.params_json = {"x" => x, "y" => y, "w" => w, "h" => h, "target" => target}.to_json
    file_id = Store.insert_file(file)
    Jobs.thumbnail(file_id)
    succeed(job, File.basename(dest))
  end

  private def self.run_import_local(job : Record) : Nil
    p = job.payload_json
    src = p["path"].as_s
    raise "no such file: #{src}" unless File.exists?(src)
    raise "not an image: #{src}" unless Omarchy::IMAGE_EXTENSIONS.includes?(File.extname(src).downcase)

    id = "local-#{Digest::SHA1.hexdigest(src)[0, 12]}"
    dest = File.join(Config.originals_dir, "#{id}#{File.extname(src).downcase}")
    note(job, "importing #{File.basename(src)}")
    File.copy(src, dest) unless File.exists?(dest)

    width, height = ImageOps.identify(dest)
    wallpaper = Wallpaper.new(id, "local")
    wallpaper.is_favorite = 1_i64
    wallpaper.url = dest
    wallpaper.page_url = src
    wallpaper.resolution = "#{width}x#{height}"
    wallpaper.added_at = Db.now
    Store.upsert_wallpaper(wallpaper)
    Store.set_favorite(id, true)

    file = WallpaperFile.new(id, "original", dest, width, height)
    file.file_size = File.size(dest)
    file.created_at = Db.now
    file_id = Store.insert_file(file)
    Jobs.thumbnail(file_id)
    succeed(job, "#{File.basename(dest)} (#{width}x#{height})")
  end

  # Streaming download with progress notes; writes to a temporary file first so
  # a crash never leaves a half file registered in the database.
  private def self.http_download(url : String, dest : String, job : Record) : Int64
    uri = URI.parse(url)
    client = HTTP::Client.new(uri)
    client.read_timeout = 120.seconds
    client.connect_timeout = 15.seconds
    tmp = "#{dest}.part"
    total = 0_i64
    begin
      client.get(uri.request_target) do |response|
        unless response.success?
          raise "HTTP #{response.status_code} for #{url}"
        end
        expected = response.headers["Content-Length"]?.try(&.to_i64?) || 0_i64
        File.open(tmp, "w") do |io|
          buffer = Bytes.new(64 * 1024)
          last = Time.instant
          while (read = response.body_io.read(buffer)) > 0
            io.write(buffer[0, read])
            total += read
            if (Time.instant - last) > 0.4.seconds
              last = Time.instant
              pct = expected > 0 ? " (#{(total * 100 // expected)}%)" : ""
              note(job, "downloading #{total // 1024} KiB#{pct}")
            end
          end
        end
      end
      File.rename(tmp, dest)
    rescue ex
      File.delete(tmp) if File.exists?(tmp)
      raise ex
    ensure
      client.close
    end
    total
  end
end
