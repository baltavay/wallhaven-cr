module Ui
  # Simple left-to-right flow layout: places labelled widgets on a row until the
  # available width runs out, then wraps. Keeps the filter bar readable whether
  # the window is 940 px wide (tiled) or 1900 px (full screen).
  class Flow
    LABEL_H = 16_f32

    def initialize(@x : Float32, @y : Float32, @width : Float32, @gap : Float32 = 10_f32)
      @cursor = @x
      @row_y = @y
      @bottom = @y
    end

    # Reserve a slot for a labelled widget and return the widget's rectangle.
    def place(label_width : Float32, widget_w : Float32, widget_h : Float32) : Raylib::Rectangle
      slot = [label_width, widget_w].max
      if @cursor > @x && (@cursor - @x) + slot > @width
        @cursor = @x
        @row_y += 44_f32
      end
      rec = Raylib::Rectangle.new(x: @cursor, y: @row_y + LABEL_H, width: widget_w, height: widget_h)
      @cursor += slot + @gap
      @bottom = [@bottom, @row_y + LABEL_H + widget_h].max
      rec
    end

    def height : Float32
      @bottom + 12_f32
    end
  end

  class App
    DETAIL_W = 300

    def draw_browse : Nil
      w = Raylib.get_screen_width
      h = Raylib.get_screen_height
      filter_h = draw_filters(w)

      grid_top = filter_h + 8
      grid_bottom = h - 36
      grid_right = w - DETAIL_W - 16

      draw_grid(grid_top, grid_bottom, grid_right)
      draw_detail(grid_top, grid_bottom, grid_right + 16)
    end

    # ---- filter bar (wraps to as many rows as the window needs)

    def draw_filters(w : Int32) : Int32
      # The bar's height depends on how many rows the widgets need, which is
      # only known after placing them; paint with last frame's height.
      Raylib.draw_rectangle(SIDEBAR_W, 0, w - SIDEBAR_W, @filter_height + 6, PANEL)
      Raylib.draw_line(SIDEBAR_W, @filter_height + 6, w, @filter_height + 6, BORDER)
      left = SIDEBAR_W + 16
      flow = Flow.new(left.to_f32, 12_f32, (w - left - 16).to_f32, 12_f32)
      mouse = Raylib.get_mouse_position

      search_rec = flow.place(70_f32, 360_f32, 30_f32)
      text("search", search_rec.x.to_i, (search_rec.y - 15).to_i, 12, MUTED)
      if text_entry(search_rec, @f_query, 1, 220)
        persist_filters
        start_search(1)
      end
      if button(flow.place(70_f32, 90_f32, 30_f32), @searching ? "…" : "Search")
        persist_filters
        start_search(1)
      end
      if button(flow.place(50_f32, 66_f32, 30_f32), "prev") && @result_page > 1
        start_search(@result_page - 1)
      end
      if button(flow.place(50_f32, 66_f32, 30_f32), "next") && @result_page < @result_last_page
        start_search(@result_page + 1)
      end
      page_rec = flow.place(90_f32, 170_f32, 30_f32)
      text("page #{@result_page}/#{@result_last_page}", page_rec.x.to_i, page_rec.y.to_i, 14, TEXT)
      text("#{@result_total} total", page_rec.x.to_i, page_rec.y.to_i + 16, 12, MUTED)

      # categories / purity bitmasks as toggle chips (multi-select)
      chip_item(flow, "category", "general", pointerof(@cat_general))
      chip_item(flow, nil, "anime", pointerof(@cat_anime))
      chip_item(flow, nil, "people", pointerof(@cat_people))
      pur = chip_item(flow, "purity", "sfw", pointerof(@pure_sfw))
      chip_item(flow, nil, "sketchy", pointerof(@pure_sketchy))
      chip_item(flow, nil, "nsfw", pointerof(@pure_nsfw))
      unless @pure_sfw || @pure_sketchy || @pure_nsfw
        text("pick a purity", pur.x.to_i, pur.y.to_i + 26, 12, ERR)
      end

      # sorting and filters
      sort_rec = flow.place(70_f32, 150_f32, 28_f32)
      text("sort", sort_rec.x.to_i, (sort_rec.y - 15).to_i, 12, MUTED)
      if dropdown(sort_rec, Wallhaven::SORTING.keys.join(";"), pointerof(@sort), pointerof(@drop_sort))
        persist_filters
      end
      if (Wallhaven::SORTING.values[@sort]? || "") == "toplist"
        if dropdown(flow.place(80_f32, 130_f32, 28_f32), Wallhaven::TOP_RANGE.keys.join(";"), pointerof(@top_range), pointerof(@drop_top))
          persist_filters
        end
      end
      if dropdown(flow.place(80_f32, 130_f32, 28_f32), Wallhaven::ORDER.keys.join(";"), pointerof(@order), pointerof(@drop_order))
        persist_filters
      end
      if dropdown(flow.place(80_f32, 128_f32, 28_f32), Wallhaven::AT_LEAST.map { |r| r.empty? ? "any size" : r }.join(";"), pointerof(@atleast), pointerof(@drop_atleast))
        persist_filters
      end
      if dropdown(flow.place(70_f32, 140_f32, 28_f32), Wallhaven::RESOLUTIONS.map { |r| r.empty? ? "any exact" : r }.join(";"), pointerof(@resolution), pointerof(@drop_res))
        persist_filters
      end
      if dropdown(flow.place(70_f32, 128_f32, 28_f32), Wallhaven::RATIOS.keys.join(";"), pointerof(@ratio), pointerof(@drop_ratio))
        persist_filters
      end

      colour_rec = flow.place(70_f32, 84_f32, 28_f32)
      text("colour", colour_rec.x.to_i, (colour_rec.y - 15).to_i, 12, MUTED)
      if text_entry(colour_rec, @f_colors, 2, 10)
        persist_filters
      end
      swatch_rec = flow.place(30_f32, 26_f32, 28_f32)
      if swatch(swatch_rec, Raylib::Color.new(r: 179, g: 56, b: 56, a: 255))
        set_color("b33838")
      end
      if swatch(flow.place(30_f32, 26_f32, 28_f32), Raylib::Color.new(r: 62, g: 94, b: 168, a: 255))
        set_color("3e5ea8")
      end
      if button(flow.place(60_f32, 70_f32, 28_f32), "clear")
        @f_colors.value = ""
        persist_filters
      end

      @filter_height = flow.height.to_i32
      @filter_height
    end

    # raygui dropdowns need the caller to own the "list is open" flag.
    # Returns true on the frame an item is committed.
    def dropdown(rec : Raylib::Rectangle, items : String, active : Int32*, open : Bool*) : Bool
      # raygui draws a dropdown even with a single entry but will not open it;
      # draw it so the value is visible and skip the toggle logic.
      if items.split(';').size <= 1
        Raygui.dropdown_box(rec, items, active, false)
        return false
      end
      if Raygui.dropdown_box(rec, items, active, open.value) == 1
        changed = open.value
        open.value = !open.value
        return changed
      end
      false
    end

    # Multi-select toggle chip: raygui's checkbox gives no clear on/off contrast
    # in a dark theme, so toggles are drawn explicitly.
    def chip_item(flow : Flow, group : String?, label : String, active : Bool*) : Raylib::Rectangle
      widget_w = measure(label, 16) + 26_f32
      group_w = group ? measure(group, 12) + 8_f32 : 0_f32
      rec = flow.place([group_w, widget_w].max, widget_w, 24_f32)
      if group
        text(group, rec.x.to_i, (rec.y - 15).to_i, 12, MUTED)
      end
      on = active.value
      Raylib.draw_rectangle_rec(rec, on ? ACCENT : CARD)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, on ? ACCENT : BORDER)
      text(label, rec.x + 13_f32, rec.y + 4_f32, 16, on ? BG : TEXT)
      if input_ready? && mouse_pressed? && Raylib.check_collision_point_rec?(Raylib.get_mouse_position, rec)
        active.value = !on
      end
      rec
    end

    def set_color(hex : String) : Nil
      @f_colors.value = hex
      persist_filters
      start_search(1)
    end

    def swatch(rec : Raylib::Rectangle, color : Raylib::Color) : Bool
      Raylib.draw_rectangle_rec(rec, color)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, BORDER)
      mouse_pressed? && Raylib.check_collision_point_rec?(Raylib.get_mouse_position, rec)
    end

    # A text box bound to `field`, focused by clicking. Returns true on Enter.
    def text_entry(rec : Raylib::Rectangle, field : Field, id : Int32, capacity : Int32) : Bool
      mouse = Raylib.get_mouse_position
      if mouse_pressed? && Raylib.check_collision_point_rec?(mouse, rec)
        @focus_id = id
      end
      edit = @focus_id == id
      result = Raygui.text_box(rec, field.buffer, capacity, edit)
      if result == 1 || (edit && Raylib.key_pressed?(Raylib::KeyboardKey::Escape))
        @focus_id = 0
        return true if result == 1
      end
      false
    end

    # ---- thumbnail grid

    def draw_grid(top : Int32, bottom : Int32, right : Int32) : Nil
      left = SIDEBAR_W + 16
      width = right - left
      height = bottom - top
      return if width < 80 || height < 80

      cell = 180
      gap = 12
      columns = [1, (width + gap) // (cell + gap)].max
      rows = (@results.size + columns - 1) // columns
      content_h = rows * (cell + gap) + gap

      auto_scroll(height, content_h)

      if @results.empty?
        message = @searching ? "searching…" : "no results yet — press Search"
        text(message, left + 20, top + 20, 18, MUTED)
      end

      Raylib.begin_scissor_mode(left, top, width, height)
      @results.each_with_index do |wallpaper, index|
        col = index % columns
        row = index // columns
        cx = left + col * (cell + gap)
        cy = top + gap + row * (cell + gap) - @grid_scroll
        next if cy + cell < top - cell || cy > bottom
        draw_cell(wallpaper, Ui.rect(cx, cy, cell, cell))
      end
      Raylib.end_scissor_mode
      draw_scrollbar(right - 6, top, height, content_h)
    end

    def draw_cell(wallpaper : Wallpaper, rec : Raylib::Rectangle) : Nil
      mouse = Raylib.get_mouse_position
      hovered = Raylib.check_collision_point_rec?(mouse, rec)
      selected = @selected.try(&.id) == wallpaper.id

      Raylib.draw_rectangle_rec(rec, CARD)
      thumb = @thumbs.fetch("w-#{wallpaper.id}", wallpaper.original_file.try(&.path), wallpaper.remote_thumb)
      drawn = false
      if thumb && (tex = texture(thumb))
        # cover-fit inside the cell
        scale = [rec.width / tex.width.to_f32, rec.height / tex.height.to_f32].max
        dw = tex.width * scale
        dh = tex.height * scale
        source = Raylib::Rectangle.new(x: (dw - rec.width) / (2 * scale), y: (dh - rec.height) / (2 * scale),
          width: rec.width / scale, height: rec.height / scale)
        Raylib.draw_texture_pro(tex, source, rec, Raylib::Vector2.new(x: 0_f32, y: 0_f32), 0_f32, Raylib::WHITE)
        drawn = true
      end

      Raylib.draw_rectangle_lines_ex(rec, selected || hovered ? 2_f32 : 1_f32,
        selected ? ACCENT : (hovered ? MUTED : BORDER))

      # badges: download state and favourite
      if wallpaper.downloaded?
        Raylib.draw_rectangle(rec.x.to_i + 6, rec.y.to_i + 6, 74, 20, OK)
        text("saved", rec.x.to_i + 12, rec.y.to_i + 9, 13, BG)
      end
      if favorite_cached?(wallpaper.id)
        Raylib.draw_rectangle(rec.x.to_i + rec.width.to_i - 30, rec.y.to_i + 6, 24, 20, FAV)
        text("*", rec.x.to_i + rec.width.to_i - 22, rec.y.to_i + 9, 14, BG)
      end
      unless drawn
        text("loading", rec.x.to_i + 10, rec.y.to_i + rec.height.to_i - 24, 13, MUTED)
      end

      if mouse_pressed? && hovered
        @selected = Store.wallpaper(wallpaper.id) || wallpaper
      end
      if mouse_pressed?(Raylib::MouseButton::Right) && hovered
        toggle_favorite(wallpaper)
      end
    end

    # ---- selected wallpaper detail

    def draw_detail(top : Int32, bottom : Int32, x : Int32) : Nil
      w = DETAIL_W
      Raylib.draw_rectangle(x, top, w, bottom - top, PANEL)
      Raylib.draw_rectangle_lines(x, top, w, bottom - top, BORDER)

      unless wallpaper = @selected
        text("nothing selected", x + 16, top + 18, 16, MUTED)
        text("click a thumbnail", x + 16, top + 40, 14, MUTED)
        return
      end

      y = top + 14
      preview = Ui.rect(x + 12, y, w - 24, 180)
      Raylib.draw_rectangle_rec(preview, CARD)
      thumb = @thumbs.fetch("w-#{wallpaper.id}", wallpaper.original_file.try(&.path), wallpaper.remote_thumb)
      if thumb && (tex = texture(thumb))
        scale = [preview.width / tex.width.to_f32, preview.height / tex.height.to_f32].min
        dw = tex.width * scale
        dh = tex.height * scale
        Raylib.draw_texture_ex(tex, Raylib::Vector2.new(x: preview.x + (preview.width - dw) / 2, y: preview.y + (preview.height - dh) / 2), 0_f32, scale, Raylib::WHITE)
      end
      y += 192

      text(wallpaper.id, x + 14, y, 18, TEXT)
      y += 24
      text("#{wallpaper.resolution}  #{wallpaper.purity}/#{wallpaper.category}", x + 14, y, 14, MUTED)
      y += 20
      text("#{wallpaper.source}#{wallpaper.downloaded? ? " · downloaded" : ""}", x + 14, y, 14, MUTED)
      y += 26

      favorite = favorite_cached?(wallpaper.id)
      if button(Ui.rect(x + 14, y, w - 28, 32), favorite ? "Remove favourite" : "Add favourite", favorite)
        toggle_favorite(wallpaper)
      end
      y += 38

      if button(Ui.rect(x + 14, y, w - 28, 32), wallpaper.downloaded? ? "Downloaded" : "Download original")
        download(wallpaper)
      end
      y += 38

      if button(Ui.rect(x + 14, y, w - 28, 32), "Open crop editor")
        open_editor(wallpaper)
        @view = View::Editor
      end
      y += 38

      if path = wallpaper.original_file.try(&.path)
        if File.exists?(path) && button(Ui.rect(x + 14, y, w - 28, 32), "Add to current theme")
          add_to_theme(path, theme_name_for(wallpaper))
        end
      end
      y += 38

      if button(Ui.rect(x + 14, y, w - 28, 32), "Copy source url")
        Raylib.set_clipboard_text(wallpaper.url || "")
        say "copied url", OK
      end
      y += 44

      # versions list
      text("versions", x + 14, y, 15, TEXT)
      y += 22
      refresh_detail
      files = @detail_files
      if files.empty?
        text("no local files yet", x + 14, y, 13, MUTED)
      end
      files.each do |file|
        text(file.label, x + 14, y, 13, file.exists? ? TEXT : ERR)
        text("#{file.file_size // 1024} KiB", x + 14, y + 15, 12, MUTED)
        if file.kind == "crop"
          if small_button(Ui.rect(x + w - 74, y - 2, 60, 24), "delete")
            File.delete(file.path) if File.exists?(file.path)
            Store.delete_file(file.id)
            say "deleted #{File.basename(file.path)}", MUTED
          end
        elsif file.exists?
          if small_button(Ui.rect(x + w - 74, y - 2, 60, 24), "theme")
            add_to_theme(file.path, theme_name_for(wallpaper))
          end
        end
        y += 34
      end
    end

    def theme_name_for(wallpaper : Wallpaper) : String
      base = "wallhaven-#{wallpaper.id}"
      base = wallpaper.id unless wallpaper.source == "wallhaven"
      base
    end

    def small_button(rec : Raylib::Rectangle, label : String) : Bool
      Raygui.set_style(Raygui::Control::Default.value, Raygui::DefaultProperty::TextSize.value, 14)
      result = Raygui.button(rec, label) == 1
      Raygui.set_style(Raygui::Control::Default.value, Raygui::DefaultProperty::TextSize.value, 16)
      result
    end

    # ---- scrolling helpers

    def auto_scroll(viewport_h : Int32, content_h : Int32) : Nil
      wheel = Raylib.get_mouse_wheel_move
      @grid_scroll -= wheel * 60_f32 if wheel != 0_f32
      max = [0_f32, (content_h - viewport_h).to_f32].max
      @grid_scroll = @grid_scroll.clamp(0_f32, max)
    end

    def draw_scrollbar(x : Int32, top : Int32, height : Int32, content_h : Int32) : Nil
      return if content_h <= height
      fraction = height.to_f32 / content_h.to_f32
      bar_h = [24, (height * fraction).to_i32].max
      max = content_h - height
      offset = max > 0 ? (@grid_scroll / max) : 0_f32
      y = top + ((height - bar_h) * offset).to_i32
      Raylib.draw_rectangle(x, top, 4, height, CARD)
      Raylib.draw_rectangle(x, y, 4, bar_h, MUTED)
    end
  end
end
