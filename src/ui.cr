require "raylib-cr"
require "raylib-cr/raygui"
require "./config"
require "./store"
require "./wallhaven"
require "./jobs"
require "./monitors"
require "./aether_import"
require "./ui/thumbs"

# raylib + raygui immediate-mode front end.
#
# One window, one event loop on the main thread. Everything slow (downloads,
# ImageMagick, HTTP) happens on the background worker or on the thumbnail
# thread; the UI only ever reads finished files and database rows.
module Ui
  # Text is rendered with a real TTF rather than raylib's ASCII-only bitmap font
  # so search queries and file names in Cyrillic (and typographic punctuation)
  # display correctly. First existing candidate wins.
  FONT_CANDIDATES = [
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/TTF/CaskaydiaMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
  ]

  FONT_SIZE = 32

  # Codepoints handed to LoadFontEx: basic latin + latin-1 + punctuation +
  # cyrillic. Anything outside this set renders as a placeholder glyph.
  def self.font_codepoints : Array(Int32)
    points = (32..0x2FF).to_a + (0x400..0x4FF).to_a
    points.concat([0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x2192, 0x00B7])
    points
  end

  # Dark palette, loosely following the Omarchy look.
  BG        = Raylib::Color.new(r: 18, g: 19, b: 23, a: 255)
  PANEL     = Raylib::Color.new(r: 24, g: 26, b: 32, a: 255)
  CARD      = Raylib::Color.new(r: 32, g: 35, b: 43, a: 255)
  BORDER    = Raylib::Color.new(r: 58, g: 63, b: 76, a: 255)
  TEXT      = Raylib::Color.new(r: 226, g: 230, b: 236, a: 255)
  MUTED     = Raylib::Color.new(r: 138, g: 145, b: 160, a: 255)
  ACCENT    = Raylib::Color.new(r: 122, g: 162, b: 247, a: 255)
  FAV       = Raylib::Color.new(r: 236, g: 112, b: 132, a: 255)
  OK        = Raylib::Color.new(r: 126, g: 214, b: 160, a: 255)
  WARN      = Raylib::Color.new(r: 235, g: 190, b: 118, a: 255)
  ERR       = Raylib::Color.new(r: 230, g: 120, b: 120, a: 255)

  def self.rect(x : Number, y : Number, w : Number, h : Number) : Raylib::Rectangle
    Raylib::Rectangle.new(x: x.to_f32, y: y.to_f32, width: w.to_f32, height: h.to_f32)
  end

  # raygui colours are `int` literals in 0xRRGGBBAA order.
  def self.pack(c : Raylib::Color) : Int32
    ((c.r.to_i32 & 0xFF) << 24) | ((c.g.to_i32 & 0xFF) << 16) |
      ((c.b.to_i32 & 0xFF) << 8) | (c.a.to_i32 & 0xFF)
  end

  # Growable null-terminated UTF-8 buffer for raygui text widgets.
  class Field
    def initialize(@capacity : Int32 = 256)
      @bytes = Slice(UInt8).new(@capacity)
      @bytes[0] = 0_u8
    end

    def buffer : UInt8*
      @bytes.to_unsafe
    end

    def value : String
      String.new(@bytes.to_unsafe)
    end

    def value=(text : String)
      @bytes.fill(0_u8)
      slice = text.to_slice
      slice = slice[0, @capacity - 1] if slice.size >= @capacity
      slice.copy_to(@bytes)
      @bytes[slice.size] = 0_u8
    end
  end

  class App
    enum View
      Browse
      Favorites
      Editor
      Queue
      Theme
    end

    SIDEBAR_W  = 208
    THUMB_SIZE = 256

    # ---- state
    @view : View = View::Browse
    @settings : Settings
    @status : String = "ready"
    @status_color : Raylib::Color = TEXT

    # browse
    @results : Array(Wallpaper) = [] of Wallpaper
    @result_page : Int32 = 1
    @result_last_page : Int32 = 1
    @result_total : Int32 = 0
    @grid_scroll : Float32 = 0_f32
    @selected : Wallpaper?
    @searching : Bool = false

    # filters
    @f_query : Field
    @f_colors : Field
    @cat_general : Bool = true
    @cat_anime : Bool = true
    @cat_people : Bool = true
    @pure_sfw : Bool = true
    @pure_sketchy : Bool = false
    @pure_nsfw : Bool = false
    @sort : Int32 = 0
    @order : Int32 = 1
    @atleast : Int32 = 0
    @resolution : Int32 = 0
    @ratio : Int32 = 0
    @top_range : Int32 = 0
    @focus_id : Int32 = 0
    @drop_sort : Bool = false
    @drop_order : Bool = false
    @drop_top : Bool = false
    @drop_atleast : Bool = false
    @drop_res : Bool = false
    @drop_ratio : Bool = false
    @drop_monitor : Bool = false

    # Cached database reads (the draw loop must not query per cell per frame).
    @favorite_ids = Set(String).new
    @detail_files = [] of WallpaperFile
    @frame : Int32 = 0
    @quit : Bool = false
    # Thread that created the GL context; the invariant guard below watches it.
    @gl_thread : UInt64 = 0_u64
    @thread_moved : Bool = false

    # favourites / theme
    @favorites : Array(Wallpaper) = [] of Wallpaper
    @fav_scroll : Float32 = 0_f32
    @theme_info : String = ""

    # queue
    @queue_scroll : Float32 = 0_f32

    # editor
    @editor_wallpaper : Wallpaper?
    @editor_source : WallpaperFile?
    @editor_versions = [] of WallpaperFile
    @editor_preview_dims : Tuple(Int32, Int32)?
    @editor_crop_rect : NamedTuple(x: Int64, y: Int64, w: Int64, h: Int64, out_w: Int32, out_h: Int32, target: String)?
    @editor_min_zoom : Float32 = 1_f32
    @editor_zoom : Float32 = 1_f32
    @editor_pan : Raylib::Vector2 = Raylib::Vector2.new(x: 0_f32, y: 0_f32)
    @editor_dragging : Bool = false
    @editor_monitor : Int32 = 0
    @editor_target : String = ""
    @monitors : Array(Monitors::Monitor) = [] of Monitors::Monitor
    @detail_crops = {} of String => Array(WallpaperFile)
    @filter_height : Int32 = 158
    @import_confirm_deadline : Int32 = 0

    # file picker
    @picker_open : Bool = false
    @picker_dir : String = ""
    @picker_entries : Array(String) = [] of String
    @picker_scroll : Float32 = 0_f32
    @picker_selected : Int32 = -1
    @f_picker_path : Field
    @theme_scroll : Float32 = 0_f32

    @thumbs : ThumbCache
    @previews : ThumbCache
    @font : Raylib::Font = Raylib::Font.new
    @using_custom_font : Bool = false
    @textures = {} of String => Raylib::Texture2D
    @texture_used = [] of String

    @search_request : Channel(Wallhaven::Query)?
    @search_response : Channel(Wallhaven::Result)?
    @search_error : Channel(String)?

    CATEGORY_LABELS = ["general", "anime", "people"]
    PURITY_LABELS   = ["sfw", "sketchy", "nsfw"]

    # Non-interactive rendering: draw *frames* frames, write a PNG of the
    # framebuffer, and exit. Used by `--capture` and by the smoke checks.
    @capture_path : String?
    @capture_frames : Int32
    @start_view : String?

    def initialize(capture_path : String? = nil, capture_frames : Int32 = 60, start_view : String? = nil)
      @capture_path = capture_path
      @capture_frames = capture_frames
      @start_view = start_view
      @settings = Config.load
      @f_query = Field.new
      @f_query.value = @settings.query
      @f_colors = Field.new(16)
      @f_colors.value = @settings.colors
      @f_picker_path = Field.new(512)
      @cat_general, @cat_anime, @cat_people = bits(@settings.categories, 3)
      @pure_sfw, @pure_sketchy, @pure_nsfw = bits(@settings.purity, 3)
      @sort = Wallhaven::SORTING.values.index(@settings.sorting) || 0
      @order = @settings.order == "asc" ? 1 : 0
      @atleast = Wallhaven::AT_LEAST.index(@settings.at_least) || 0
      @resolution = Wallhaven::RESOLUTIONS.index(@settings.resolutions) || 0
      @ratio = Wallhaven::RATIOS.values.index(@settings.ratios) || 0
      @thumbs = ThumbCache.new(THUMB_SIZE)
      @previews = ThumbCache.new(2048, :preview)
      @monitors = Monitors.all
      @editor_target = (@monitors.first? || Monitors::FALLBACK).name
      @search_request = Channel(Wallhaven::Query).new(4)
      @search_response = Channel(Wallhaven::Result).new(4)
      @search_error = Channel(String).new(4)
    end

    private def bits(mask : String, count : Int32) : Tuple(Bool, Bool, Bool)
      values = (0...count).map { |i| mask[i]?.try(&.==('1')) || false }
      {values[0]? || false, values[1]? || false, values[2]? || false}
    end

    # ---- helpers

    def say(message : String, color : Raylib::Color = TEXT) : Nil
      @status = message
      @status_color = color
    end

    def categories_mask : String
      "#{@cat_general ? '1' : '0'}#{@cat_anime ? '1' : '0'}#{@cat_people ? '1' : '0'}"
    end

    def purity_mask : String
      "#{@pure_sfw ? '1' : '0'}#{@pure_sketchy ? '1' : '0'}#{@pure_nsfw ? '1' : '0'}"
    end

    def current_query(page : Int32 = @result_page) : Wallhaven::Query
      Wallhaven::Query.new(
        @f_query.value.strip,
        categories_mask,
        purity_mask,
        Wallhaven::SORTING.values[@sort]? || "date_added",
        Wallhaven::ORDER.values[@order]? || "asc",
        @sort == Wallhaven::SORTING.values.index("toplist") ? (Wallhaven::TOP_RANGE.values[@top_range]? || "") : "",
        Wallhaven::AT_LEAST[@atleast]? || "",
        Wallhaven::RESOLUTIONS[@resolution]? || "",
        Wallhaven::RATIOS.values[@ratio]? || "",
        @f_colors.value.strip.gsub("#", ""),
        page,
        "")
    end

    def persist_filters : Nil
      @settings.query = @f_query.value.strip
      @settings.categories = categories_mask
      @settings.purity = purity_mask
      @settings.sorting = Wallhaven::SORTING.values[@sort]? || "date_added"
      @settings.order = Wallhaven::ORDER.values[@order]? || "asc"
      @settings.at_least = Wallhaven::AT_LEAST[@atleast]? || ""
      @settings.resolutions = Wallhaven::RESOLUTIONS[@resolution]? || ""
      @settings.ratios = Wallhaven::RATIOS.values[@ratio]? || ""
      @settings.colors = @f_colors.value.strip
      Config.save(@settings)
    end

    # ---- search (asynchronous: the HTTP call runs off the UI thread)

    def start_search(page : Int32 = 1) : Nil
      return if @searching
      @searching = true
      say "searching page #{page}…", WARN
      begin
        @search_request.try(&.send(current_query(page)))
      rescue Channel::ClosedError
      end
    end

    # Crystal 1.21 `Channel#receive?` blocks until a value or close; `select`
    # with an `else` branch is the non-blocking form.
    private def try_receive(channel : Channel(T)) : T? forall T
      select
      when value = channel.receive
        value
      else
        nil
      end
    end

    def poll_search : Nil
      if response = @search_response.try { |ch| try_receive(ch) }
        @searching = false
        @results = response.data
        @result_page = response.page
        @result_last_page = response.last_page
        @result_total = response.total
        @grid_scroll = 0_f32
        response.data.each { |w| Store.upsert_wallpaper(w) }
        say "#{response.data.size} results · page #{response.page}/#{response.last_page} · #{response.total} total", OK
      end
      if error = @search_error.try { |ch| try_receive(ch) }
        @searching = false
        say error, ERR
      end
    end

    # Run the search worker thread (one per app, reused).
    def start_worker : Nil
      request = @search_request.not_nil!
      response = @search_response.not_nil!
      errors = @search_error.not_nil!
      api_key = @settings.api_key
      Fiber::ExecutionContext::Isolated.new("wh-search") do
        # Visible in htop and, if the process ever dumps a core, in gdb.
        Thread.name = "wh-search"
        Db.setup
        loop do
          query = request.receive
          client = Wallhaven.new(api_key)
          begin
            response.send(client.search_pages(query, 1))
          rescue e
            errors.send(e.message || "search failed")
          ensure
            client.close
          end
        end
      rescue Channel::ClosedError
      end
    end

    # ---- texture cache (UI thread only)

    def texture(path : String) : Raylib::Texture2D?
      if tex = @textures[path]?
        return tex
      end
      return nil unless File.exists?(path)
      tex = Raylib.load_texture(path)
      return nil if tex.id == 0
      Raylib.set_texture_filter(tex, Raylib::TextureFilter::Bilinear.value)
      @textures[path] = tex
      @texture_used << path
      tex
    end

    # Called once per frame, before drawing starts. Deleting a texture while a
    # frame is being built is unsafe: raylib batches draw calls and flushes them
    # at the end of the frame, so an id unloaded mid-frame is still referenced
    # by the pending batch. Unloading between frames keeps GL object lifetime
    # aligned with the frame boundary.
    def evict_textures : Nil
      while @texture_used.size > 220
        old = @texture_used.shift
        if tex = @textures.delete(old)
          Raylib.unload_texture(tex)
        end
      end
    end

    def unload_textures : Nil
      @textures.each_value { |t| Raylib.unload_texture(t) }
      @textures.clear
      @texture_used.clear
    end

    # The X server reports a spurious mouse-button release in the first frames,
    # which would "click" whatever is under the pointer. Ignore input until the
    # window has settled.
    INPUT_SETTLE_FRAMES = 4

    # Input is ignored until the window has settled and only while it has focus:
    # an X11/XWayland window that never receives focus can report a stale mouse
    # button release, which would otherwise "click" whatever is under the cursor.
    def input_ready? : Bool
      return false if @capture_path # rendering-only mode: no input at all
      @frame > INPUT_SETTLE_FRAMES && Raylib.window_focused?
    end

    def mouse_pressed?(button : Raylib::MouseButton = Raylib::MouseButton::Left) : Bool
      input_ready? && Raylib.mouse_button_pressed?(button)
    end

    def mouse_released?(button : Raylib::MouseButton = Raylib::MouseButton::Left) : Bool
      input_ready? && Raylib.mouse_button_released?(button)
    end

    def mouse_down?(button : Raylib::MouseButton = Raylib::MouseButton::Left) : Bool
      input_ready? && Raylib.mouse_button_down?(button)
    end

    # ---- drawing helpers

    def button(bounds : Raylib::Rectangle, label : String, active : Bool = false) : Bool
      if active
        Raygui.set_style(Raygui::Control::Button.value, Raygui::ControlProperty::BaseColorNormal.value, Ui.pack(ACCENT))
        Raygui.set_style(Raygui::Control::Button.value, Raygui::ControlProperty::TextColorNormal.value, Ui.pack(BG))
      else
        Raygui.set_style(Raygui::Control::Button.value, Raygui::ControlProperty::BaseColorNormal.value, Ui.pack(CARD))
        Raygui.set_style(Raygui::Control::Button.value, Raygui::ControlProperty::TextColorNormal.value, Ui.pack(TEXT))
      end
      Raygui.button(bounds, label) == 1
    end

    def apply_style : Nil
      Raygui.set_style(Raygui::Control::Default.value, Raygui::DefaultProperty::TextSize.value, 16)
      Raygui.set_style(Raygui::Control::Default.value, Raygui::DefaultProperty::BackgroundColor.value, Ui.pack(PANEL))
      Raygui.set_style(Raygui::Control::Default.value, Raygui::DefaultProperty::LineColor.value, Ui.pack(BORDER))

      {Raygui::Control::Label, Raygui::Control::Button, Raygui::Control::Toggle, Raygui::Control::Slider,
       Raygui::Control::ProgressBar, Raygui::Control::ComboBox, Raygui::Control::DropdownBox, Raygui::Control::CheckBox,
       Raygui::Control::TextBox, Raygui::Control::ListView, Raygui::Control::ColorPicker, Raygui::Control::ScrollBar}.each do |c|
        Raygui.set_style(c.value, Raygui::ControlProperty::BaseColorNormal.value, Ui.pack(CARD))
        Raygui.set_style(c.value, Raygui::ControlProperty::BorderColorNormal.value, Ui.pack(BORDER))
        Raygui.set_style(c.value, Raygui::ControlProperty::TextColorNormal.value, Ui.pack(TEXT))
        Raygui.set_style(c.value, Raygui::ControlProperty::BaseColorFocused.value, Ui.pack(PANEL))
        Raygui.set_style(c.value, Raygui::ControlProperty::BorderColorFocused.value, Ui.pack(ACCENT))
        Raygui.set_style(c.value, Raygui::ControlProperty::TextColorFocused.value, Ui.pack(TEXT))
        Raygui.set_style(c.value, Raygui::ControlProperty::BaseColorPressed.value, Ui.pack(ACCENT))
        Raygui.set_style(c.value, Raygui::ControlProperty::TextColorPressed.value, Ui.pack(BG))
      end
      Raygui.set_style(Raygui::Control::Label.value, Raygui::ControlProperty::TextColorNormal.value, Ui.pack(TEXT))
      Raygui.set_style(Raygui::Control::Toggle.value, Raygui::ControlProperty::TextAlignment.value, Raygui::TextAlignment::Center.value)
      Raygui.set_style(Raygui::Control::Button.value, Raygui::ControlProperty::TextAlignment.value, Raygui::TextAlignment::Center.value)
    end

    # ---- main loop

    def run : Nil
      flags = Raylib::ConfigFlags::WindowResizable.value | Raylib::ConfigFlags::MSAA4xHint.value | Raylib::ConfigFlags::VSyncHint.value
      Raylib.set_config_flags(flags)
      Raylib.init_window(1280, 820, "wallhaven-cr")
      @gl_thread = Thread.current.object_id
      Raylib.set_window_min_size(980, 620)
      Raylib.set_target_fps(60)
      Raylib.set_exit_key(0) # Escape is used by the UI, not to quit
      Db.setup
      load_font
      apply_style
      start_worker
      Jobs.start
      refresh_favorites
      refresh_theme_info
      say "ready · #{Store.count_wallpapers} wallpapers · #{Store.count_favorites} favourites"
      autoload if @results.empty?
      apply_start_view(@start_view)

      until Raylib.close_window? || @quit
        @frame += 1
        # Safety net: if the UI fiber is ever rescheduled onto another thread,
        # every GL call from here on would fault. Stop before drawing anything
        # instead of dying with an unexplained SIGSEGV in libGLdispatch.
        if Thread.current.object_id != @gl_thread
          unless @thread_moved
            @thread_moved = true
            STDERR.puts "wallhaven-cr: the UI fiber moved to thread #{Thread.current.object_id} " \
                        "(GL context belongs to #{@gl_thread}); stopping instead of faulting"
          end
          break
        end
        handle_keys
        if input_ready?
          Raygui.unlock
        else
          # raygui must not react to the spurious first-frame release either.
          Raygui.lock
        end
        poll_search
        evict_textures
        Raylib.begin_drawing
        Raylib.clear_background(BG)
        draw_sidebar
        draw_content
        draw_status
        Raylib.end_drawing
        if path = @capture_path
          if @frame >= @capture_frames
            # raylib's TakeScreenshot writes the basename into the working
            # directory, so move it to the requested path afterwards.
            Raylib.take_screenshot(File.basename(path))
            written = File.basename(path)
            if File.exists?(written) && File.expand_path(written) != File.expand_path(path)
              File.delete(path) if File.exists?(path)
              FileUtils.mv(written, path)
            end
            File.write("#{path}.status", @status)
            break
          end
        end
      end
      shutdown
    end

    # Order matters. Workers are stopped first (they spawn image tools, so no
    # external process may still be starting while the GPU is being released),
    # then GL resources are freed while the context is still current, and only
    # then is the window closed. Closing the window ourselves is important: if
    # the process is left to exit with GLFW still owning the context, glvnd and
    # the driver are torn down by static destructors at exit, concurrently with
    # threads that are still alive — the shape of a SIGSEGV inside
    # libGLdispatch.
    private def shutdown : Nil
      @thumbs.stop
      @previews.stop
      Jobs.stop
      # With the context no longer owned by this thread, freeing GL objects or
      # closing the window would fault; leave the process to exit.
      return if @thread_moved
      unload_textures
      Raylib.unload_font(@font) if @using_custom_font
      Raylib.close_window
    end

    def apply_start_view(view : String?) : Nil
      return unless view
      @view = case view.downcase
              when "favorites", "favourites" then View::Favorites
              when "editor"                  then View::Editor
              when "queue", "downloads"      then View::Queue
              when "theme"                   then View::Theme
              else                                View::Browse
              end
      view_changed
    end

    # Load the UI font (see FONT_CANDIDATES) and hand it to raygui as well.
    def load_font : Nil
      path = FONT_CANDIDATES.find { |candidate| File.exists?(candidate) }
      unless path
        @font = Raylib.get_font_default
        return
      end
      points = Ui.font_codepoints
      slice = Slice(Int32).new(points.size) { |i| points[i] }
      font = Raylib.load_font_ex(path, FONT_SIZE, slice.to_unsafe, slice.size)
      return if font.glyph_count == 0
      Raylib.set_texture_filter(font.texture, Raylib::TextureFilter::Bilinear.value)
      @font = font
      @using_custom_font = true
      Raygui.set_font(font)
    end

    # Wrapper so every label goes through the loaded font.
    def text(content : String, x : Number, y : Number, size : Int32, color : Raylib::Color) : Nil
      Raylib.draw_text_ex(@font, content, Raylib::Vector2.new(x: x.to_f32, y: y.to_f32), size.to_f32, 0.4_f32, color)
    end

    def measure(content : String, size : Int32) : Float32
      Raylib.measure_text_ex(@font, content, size.to_f32, 0.4_f32).x
    end

    # Prefer the full summary text, fall back to a compact form, and only then
    # give up: `truncate` on a guessed character width produced things like
    # "26…" for a list of 262 entries.
    def fitted(full : String, compact : String, available : Float32) : String?
      return full if measure(full, 15) <= available
      return compact if measure(compact, 15) <= available
      nil
    end

    def autoload : Nil
      return if (@settings.api_key || "").empty?
      start_search(1)
    end

    def refresh_theme_info : Nil
      theme = Omarchy.current_theme_name || "none"
      count = Omarchy.backgrounds.size
      @theme_info = "theme: #{theme} · #{count} backgrounds"
    end

    def refresh_favorites : Nil
      @favorites = Store.favorites
      @favorite_ids = Store.favorite_ids
    end

    def favorite_cached?(id : String) : Bool
      @favorite_ids.includes?(id)
    end

    def refresh_detail(force : Bool = false) : Nil
      wallpaper = @selected
      return unless wallpaper
      return unless force || @frame % 30 == 0
      @detail_files = Store.files_for(wallpaper.id)
    end

    def draw_sidebar : Nil
      h = Raylib.get_screen_height
      Raylib.draw_rectangle(0, 0, SIDEBAR_W, h, PANEL)
      Raylib.draw_line(SIDEBAR_W, 0, SIDEBAR_W, h, BORDER)

      text("wallhaven-cr", 20, 22, 22, TEXT)
      text("wallpaper manager", 20, 48, 13, MUTED)

      y = 88
      nav = {
        View::Browse    => "Browse",
        View::Favorites => "Favourites",
        View::Editor    => "Crop editor",
        View::Queue     => "Downloads",
        View::Theme     => "Theme",
      }
      nav.each do |view, label|
        if button(Ui.rect(16, y, SIDEBAR_W - 32, 34), label, @view == view)
          @view = view
          view_changed
        end
        y += 40
      end

      # Bottom block is anchored to the window edge; the stats above it are
      # skipped when the window is too short to hold both.
      text(@theme_info, 16, h - 26, 12, MUTED)
      label = if !AetherImport.available?
                "No aether data"
              elsif @import_confirm_deadline > @frame
                "Press again to import"
              else
                "Import old favourites"
              end
      # Importing can queue thousands of downloads, so it needs a second press,
      # and it never reacts before the window has settled (a stale X11 mouse
      # release would otherwise click it on startup).
      if Raygui.button(Ui.rect(16, h - 62, SIDEBAR_W - 32, 30), label) == 1 && AetherImport.available? && input_ready?
        if @import_confirm_deadline > @frame
          @import_confirm_deadline = 0
          run_import
        else
          @import_confirm_deadline = @frame + 300
          say "press again to import the aether favourites", WARN
        end
      end

      bottom_y = h - 72
      y += 12
      Raylib.draw_line(16, y, SIDEBAR_W - 16, y, BORDER)
      y += 14
      return if y > bottom_y

      counts = safe_counts
      text("queue", 20, y, 14, MUTED)
      y += 20
      text("queued #{counts["queued"]}  running #{counts["running"]}", 20, y, 13, TEXT)
      y += 18
      failed = counts["failed"]
      text("failed #{failed}  done #{counts["succeeded"]}", 20, y, 13, failed > 0 ? ERR : MUTED)
      y += 26
      return if y > bottom_y

      text("library", 20, y, 14, MUTED)
      y += 20
      text("#{Store.count_wallpapers} wallpapers", 20, y, 13, TEXT)
      y += 18
      text("#{Store.count_favorites} favourites", 20, y, 13, TEXT)
      y += 26
      return if y > bottom_y

      text("api key", 20, y, 14, MUTED)
      y += 20
      has_key = !(@settings.api_key || "").empty?
      text(has_key ? "configured" : "missing (NSFW off)", 20, y, 13, has_key ? OK : WARN)
    end

    def safe_counts : Hash(String, Int64)
      Jobs.counts
    rescue
      {"queued" => 0_i64, "running" => 0_i64, "succeeded" => 0_i64, "failed" => 0_i64}
    end

    def run_import : Nil
      if AetherImport.available?
        w, l, s = AetherImport.run
        say "queued #{w} wallhaven + #{l} local imports (#{s} skipped)", OK
      else
        say "no ~/.config/aether/favorites.json found", WARN
      end
    end

    def view_changed : Nil
      case @view
      when View::Favorites
        refresh_favorites
        refresh_detail_crops
        @fav_scroll = 0_f32
      when View::Theme
        refresh_theme_info
      when View::Queue
        @queue_scroll = 0_f32
      when View::Editor
        # Open with the current selection, or the newest downloaded wallpaper so
        # the editor is never blank.
        target = @selected || Store.favorites.first? || Store.all_files("original").last?
        if target.is_a?(Wallpaper)
          open_editor(target)
        elsif file = target
          if wallpaper = Store.wallpaper(file.wallpaper_id)
            @selected = wallpaper
            open_editor(wallpaper)
          end
        end
      else
      end
    end

    def draw_content : Nil
      case @view
      when View::Browse    then draw_browse
      when View::Favorites then draw_favorites
      when View::Editor    then draw_editor
      when View::Queue     then draw_queue
      when View::Theme     then draw_theme
      end
      draw_picker if @picker_open
    end

    # Escape closes the picker; Ctrl+Q and Ctrl+W quit (Escape-to-quit is
    # disabled so the key stays available for the UI).
    def handle_keys : Nil
      return unless input_ready?
      if Raylib.key_pressed?(Raylib::KeyboardKey::Escape)
        @picker_open = false
        @focus_id = 0
      end
      ctrl = Raylib.key_down?(Raylib::KeyboardKey::LeftControl) || Raylib.key_down?(Raylib::KeyboardKey::RightControl)
      if ctrl && (Raylib.key_pressed?(Raylib::KeyboardKey::Q) || Raylib.key_pressed?(Raylib::KeyboardKey::W))
        @quit = true
      end
    end

    def draw_status : Nil
      h = Raylib.get_screen_height
      Raylib.draw_rectangle(SIDEBAR_W, h - 28, Raylib.get_screen_width - SIDEBAR_W, 28, PANEL)
      Raylib.draw_line(SIDEBAR_W, h - 28, Raylib.get_screen_width, h - 28, BORDER)
      text(@status, SIDEBAR_W + 14, h - 21, 15, @status_color)
      text("fps #{Raylib.get_fps}", Raylib.get_screen_width - 96, h - 21, 13, MUTED)
    end

    # ---- per-wallpaper actions shared by views

    def toggle_favorite(w : Wallpaper) : Nil
      value = !favorite_cached?(w.id)
      Store.set_favorite(w.id, value)
      w.is_favorite = value ? 1_i64 : 0_i64
      refresh_favorites
      say "#{w.id}: #{value ? "added to" : "removed from"} favourites", value ? OK : MUTED
    end

    def download(w : Wallpaper) : Nil
      if path = w.original_file.try(&.path)
        return say "#{w.id} already downloaded", MUTED if File.exists?(path)
      end
      url = w.url
      unless url
        return say "#{w.id} has no source url", ERR
      end
      Jobs.download_wallpaper(w.id, url)
      say "queued download of #{w.id}", OK
    end

    def add_to_theme(path : String, name : String? = nil) : Nil
      dest = Omarchy.add_background(path, name)
      refresh_theme_info
      say "added #{File.basename(dest)} to #{Omarchy.current_theme_name || "theme"}", OK
    rescue e
      say e.message || "could not add to theme", ERR
    end
  end
end

require "./ui/browse"
require "./ui/favorites"
require "./ui/editor"
require "./ui/queue_view"
require "./ui/theme_view"
require "./ui/picker"

module Ui
  def self.run(capture_path : String? = nil, capture_frames : Int32 = 60, start_view : String? = nil) : Nil
    app = App.new(capture_path, capture_frames, start_view)
    # The window, and every GL call, must stay on one thread for the life of the
    # process: an OpenGL context is only current on the thread that created it.
    # Crystal's default (Parallel) execution context is free to resume the main
    # fiber on a pool thread after any park, which is exactly what happened in
    # the field — the UI loop ended up on thread "DEFAULT-0" while the real main
    # thread sat idle in the thread pool, and the next flush of raylib's render
    # batch segfaulted inside libGLdispatch with a NULL dispatch table.
    # `Isolated` guarantees its fiber always runs on the same system thread.
    ui = Fiber::ExecutionContext::Isolated.new("wh-ui") { app.run }
    ui.join
  end
end
