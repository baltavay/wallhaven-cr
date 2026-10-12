require "http/client"
require "../config"
require "../images"

module Ui
  # On-demand thumbnail cache with its own worker thread.
  #
  # The grid asks for a thumbnail every frame; on a miss the request is queued
  # (local ImageMagick run, or an HTTP fetch of the remote preview) and the cell
  # renders a placeholder until the file exists. Nothing blocks the UI thread.
  class ThumbCache
    record Request, key : String, local : String?, remote : String?

    def initialize(@size : Int32 = 256, @mode : Symbol = :square)
      @dir = File.join(Config.thumbs_dir, "cache")
      FileUtils.mkdir_p(@dir)
      @pending = Set(String).new
      @failed = Set(String).new
      @mutex = Mutex.new
      @queue = Channel(Request).new(1024)
      @context = Fiber::ExecutionContext::Isolated.new("wh-thumbs") do
        # Thread names are capped at 15 bytes by prctl(PR_SET_NAME); longer ones
        # are silently dropped. Short and greppable on purpose.
        Thread.name = @mode == :preview ? "wh-previews" : "wh-thumbs"
        work
      end
    end

    def path_for(key : String) : String?
      file = File.join(@dir, "#{safe(key)}.jpg")
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
      @context.join
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
      dest = File.join(@dir, "#{safe(request.key)}.jpg")
      if (local = request.local) && File.exists?(local)
        render(local, dest)
        return
      end
      remote = request.remote
      raise "no source for #{request.key}" unless remote
      temp = File.join(@dir, "tmp-#{safe(request.key)}#{File.extname(remote).presence || ".jpg"}")
      download(remote, temp)
      begin
        render(temp, dest)
      ensure
        File.delete(temp) if File.exists?(temp)
      end
    end

    private def render(src : String, dest : String) : Nil
      if @mode == :preview
        ImageOps.preview(src, dest, @size)
      else
        ImageOps.thumbnail(src, dest, @size)
      end
    end

    private def download(url : String, dest : String) : Nil
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.read_timeout = 20.seconds
      client.connect_timeout = 8.seconds
      begin
        response = client.get(uri.request_target)
        raise "HTTP #{response.status_code}" unless response.success?
        File.write(dest, response.body)
      ensure
        client.close
      end
    end

    private def safe(key : String) : String
      key.gsub(/[^A-Za-z0-9._-]+/, "_")
    end
  end
end
