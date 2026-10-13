require "http/client"
require "../atomic_file"
require "../config"
require "../images"

module Ui
  # On-demand thumbnail cache with its own worker thread. Thumbnails are whole
  # images, fitted (never cropped, never stretched).
  #
  # The grid asks for a thumbnail every frame; on a miss the request is queued
  # (local ImageMagick run, or an HTTP fetch of the remote preview) and the cell
  # renders a placeholder until the file exists. Nothing blocks the UI thread.
  class ThumbCache
    record Request, key : String, local : String?, remote : String?

    # Thumbnails are latency-bound (HTTP) and process-bound (a tool per image), so
    # several run side by side.
    WORKERS = 3

    @workers : Array(Fiber::ExecutionContext::Isolated)

    def initialize(@size : Int32 = 448, @thread_name : String = "wh-thumbs")
      @dir = Config.thumb_cache_dir
      @pending = Set(String).new
      @failed = Set(String).new
      @mutex = Mutex.new
      @clients = {} of Tuple(UInt64, String) => HTTP::Client
      @clients_mutex = Mutex.new
      @queue = Channel(Request).new(1024)
      # Thread names are capped at 15 bytes by prctl(PR_SET_NAME); longer ones are
      # silently dropped. Short and greppable on purpose.
      @workers = [] of Fiber::ExecutionContext::Isolated
      WORKERS.times do |index|
        name = index == 0 ? @thread_name : "#{@thread_name}#{index + 1}"[0, 15]
        @workers << Fiber::ExecutionContext::Isolated.new(name) do
          Thread.name = name
          work
        end
      end
    end

    def path_for(key : String) : String?
      file = Config.thumb_cache_path(key)
      File.exists?(file) ? file : nil
    end

    # Returns a cached thumbnail path, or schedules work and returns nil.
    def fetch(key : String, local : String?, remote : String?) : String?
      if path = path_for(key)
        return path
      end
      @mutex.synchronize do
        return nil if @pending.includes?(key) || @failed.includes?(key)
        return nil if local.nil? && remote.nil?
        return nil unless (local && File.exists?(local)) || remote
        @pending << key
      end
      begin
        @queue.send(Request.new(key, local, remote))
      rescue Channel::ClosedError
      end
      nil
    end

    def stop : Nil
      @queue.close
      @workers.each(&.join)
      close_clients
    end

    private def work : Nil
      loop do
        request = @queue.receive? || break
        begin
          produce(request)
        rescue
          @mutex.synchronize { @failed << request.key }
        ensure
          @mutex.synchronize { @pending.delete(request.key) }
        end
      end
    end

    private def produce(request : Request) : Nil
      dest = Config.thumb_cache_path(request.key)
      if (local = request.local) && File.exists?(local)
        render(local, dest)
        return
      end
      remote = request.remote
      raise "no source for #{request.key}" unless remote
      # wallhaven's own thumbnails are JPEGs, already small and already the shape the
      # views want (they are drawn contain-fit), so store them as they arrive rather
      # than spending a vips process on them. Anything else is normalised.
      if remote_ready_to_cache?(remote)
        AtomicFile.write(dest) { |target| download(remote, target) }
        return
      end

      temp = File.join(@dir, "tmp-#{key_safe(request.key)}#{File.extname(remote).presence || ".jpg"}")
      download(remote, temp)
      begin
        render(temp, dest)
      ensure
        File.delete(temp) if File.exists?(temp)
      end
    end

    # True when the remote image can go into the cache untouched: a JPEG (what
    # wallhaven serves) that raylib will load directly.
    private def remote_ready_to_cache?(url : String) : Bool
      ext = File.extname(URI.parse(url).path).downcase
      ext == ".jpg" || ext == ".jpeg"
    rescue
      false
    end

    private def key_safe(key : String) : String
      key.gsub(/[^A-Za-z0-9._-]+/, "_")
    end

    # Whole-image thumbnails: every view shows the wallpaper rather than a centre
    # crop of it, so this is the only shape produced.
    private def render(src : String, dest : String) : Nil
      ImageOps.preview(src, dest, @size)
    end

    # One HTTP client per worker and host, kept alive: a fresh TLS handshake per
    # thumbnail was half the cost of fetching one (measured 66 ms per tile, of
    # which ~30 ms was the handshake). Each worker owns its clients, so nothing is
    # shared across threads.
    private def download(url : String, dest : String) : Nil
      uri = URI.parse(url)
      host = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      key = {Thread.current.object_id, host}
      begin
        response = client_for(key, uri).get(uri.request_target)
      rescue error
        # a kept-alive connection can be closed by the server while idle: drop it
        # and try once on a fresh one before giving up
        @clients_mutex.synchronize { @clients.delete(key).try(&.close) }
        begin
          response = client_for(key, uri).get(uri.request_target)
        rescue retry_error
          raise IO::Error.new("#{error.message} (retry: #{retry_error.message})")
        end
      end

      raise "HTTP #{response.status_code}" unless response.success?
      File.write(dest, response.body)
    end

    private def client_for(key : Tuple(UInt64, String), uri : URI) : HTTP::Client
      @clients_mutex.synchronize do
        @clients[key] ||= HTTP::Client.new(uri).tap do |client|
          client.read_timeout = 20.seconds
          client.connect_timeout = 8.seconds
        end
      end
    end

    private def close_clients : Nil
      @clients_mutex.synchronize do
        @clients.each_value do |client|
          client.close
        rescue
        end
        @clients.clear
      end
    end

  end
end
