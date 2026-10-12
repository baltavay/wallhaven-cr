require "db"
require "sqlite3"
require "./config"

# Thread-safe SQLite access.
#
# crystal-db's pool is not safe when a connection migrates between scheduler
# threads (statement cache races -> SQLITE_MISUSE -> SIGSEGV). The UI thread and
# the background worker thread therefore each get their own single-connection
# `DB::Database`; a connection never leaves the thread that opened it.
module Db
  MIGRATIONS = [
    # 1
    <<-SQL,
    CREATE TABLE IF NOT EXISTS wallpapers (
      id          TEXT PRIMARY KEY,
      source      TEXT NOT NULL,
      url         TEXT,
      page_url    TEXT,
      resolution  TEXT,
      category    TEXT,
      purity      TEXT,
      colors_json TEXT,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      meta_json   TEXT,
      added_at    INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS files (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      wallpaper_id TEXT NOT NULL REFERENCES wallpapers(id) ON DELETE CASCADE,
      kind         TEXT NOT NULL,
      path         TEXT NOT NULL,
      width        INTEGER NOT NULL,
      height       INTEGER NOT NULL,
      file_size    INTEGER NOT NULL DEFAULT 0,
      crop_index   INTEGER,
      params_json  TEXT,
      created_at   INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_files_wallpaper ON files(wallpaper_id);
    CREATE INDEX IF NOT EXISTS idx_files_kind ON files(kind);

    CREATE TABLE IF NOT EXISTS jobs (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      kind        TEXT NOT NULL,
      payload     TEXT NOT NULL,
      status      TEXT NOT NULL,
      attempts    INTEGER NOT NULL DEFAULT 0,
      error       TEXT,
      note        TEXT,
      result      TEXT,
      created_at  INTEGER NOT NULL,
      started_at  INTEGER,
      finished_at INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status, id);

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    SQL
  ]

  REGISTRY_MUTEX = Mutex.new
  REGISTRY       = {} of UInt64 => DB::Database

  # A `DB::Database` private to the calling thread.
  def self.conn : DB::Database
    key = Thread.current.object_id
    REGISTRY_MUTEX.synchronize do
      REGISTRY[key] ||= open
    end
  end

  private def self.open : DB::Database
    db = DB.open("sqlite3:#{Config.db_path}?initial_pool_size=1&max_pool_size=1")
    db.exec "PRAGMA journal_mode = WAL"
    db.exec "PRAGMA synchronous = NORMAL"
    db.exec "PRAGMA busy_timeout = 5000"
    db.exec "PRAGMA foreign_keys = ON"
    db
  end

  # Open a connection on the current thread and apply pending migrations.
  def self.setup : Nil
    c = conn
    current = (c.query_one?("SELECT value FROM meta WHERE key = 'schema_version'", as: String) rescue nil).try(&.to_i?) || 0
    MIGRATIONS.each_with_index do |sql, i|
      version = i + 1
      next if version <= current
      c.using_connection do |conn|
        conn.exec "BEGIN"
        begin
          sql.split(';').each do |stmt|
            s = stmt.strip
            next if s.empty?
            conn.exec s
          end
          conn.exec "INSERT INTO meta(key, value) VALUES('schema_version', ?)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value", version
          conn.exec "COMMIT"
        rescue e
          conn.exec "ROLLBACK"
          raise e
        end
      end
    end
  end

  def self.now : Int64
    Time.utc.to_unix
  end
end
