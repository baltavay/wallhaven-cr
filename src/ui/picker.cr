module Ui
  class App
    PICKER_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif .bmp .avif]

    # Overlay file browser for adding a wallpaper that is already on disk.
    def open_picker : Nil
      @picker_open = true
      @picker_dir = default_picker_dir
      @picker_selected = -1
      @picker_scroll = 0_f32
      @f_picker_path.value = @picker_dir
      @picker_entries = list_dir(@picker_dir)
    end

    def default_picker_dir : String
      candidates = [
        Omarchy.wallpapers_dir,
        File.join(ENV["HOME"]? || "/", "Pictures"),
        ENV["HOME"]? || "/",
      ]
      candidates.find { |dir| Dir.exists?(dir) } || "/"
    end

    def list_dir(dir : String) : Array(String)
      return [] of String unless Dir.exists?(dir)
      entries = Dir.children(dir).reject { |name| name.starts_with?(".") }
      dirs = entries.select { |name| Dir.exists?(File.join(dir, name)) }.sort
      files = entries.select { |name| PICKER_EXTENSIONS.includes?(File.extname(name).downcase) }.sort
      dirs.map { |name| "#{name}/" } + files
    end

    def draw_picker : Nil
      width = Raylib.get_screen_width
      height = Raylib.get_screen_height
      panel_w = [720, width - 80].min
      panel_h = [540, height - 80].min
      x = (width - panel_w) // 2
      y = (height - panel_h) // 2

      Raylib.draw_rectangle(0, 0, width, height, Raylib::Color.new(r: 0, g: 0, b: 0, a: 150))
      Raylib.draw_rectangle(x, y, panel_w, panel_h, PANEL)
      Raylib.draw_rectangle_lines_ex(Ui.rect(x, y, panel_w, panel_h), 1_f32, BORDER)

      text("add a local wallpaper", x + 16, y + 14, 20, TEXT)

      path_rec = Ui.rect(x + 16, y + 46, panel_w - 210, 30)
      if text_entry(path_rec, @f_picker_path, 9, 512)
        goto_picker_dir(@f_picker_path.value)
      end
      if button(Ui.rect(x + panel_w - 186, y + 46, 84, 30), "Go")
        goto_picker_dir(@f_picker_path.value)
      end
      if button(Ui.rect(x + panel_w - 96, y + 46, 80, 30), "Up")
        goto_picker_dir(File.dirname(@picker_dir))
      end

      list_y = y + 86
      list_h = panel_h - 86 - 56
      row_h = 24
      Raylib.draw_rectangle(x + 16, list_y, panel_w - 32, list_h, CARD)
      Raylib.draw_rectangle_lines(x + 16, list_y, panel_w - 32, list_h, BORDER)

      content_h = @picker_entries.size * row_h + 8
      @picker_scroll = picker_scrolled(list_y, list_h, content_h)

      mouse = Raylib.get_mouse_position
      Raylib.begin_scissor_mode(x + 16, list_y, panel_w - 32, list_h)
      @picker_entries.each_with_index do |entry, index|
        ry = list_y + 4 + index * row_h - @picker_scroll
        next if ry + row_h < list_y || ry > list_y + list_h
        rec = Ui.rect(x + 18, ry, panel_w - 36, row_h)
        hovered = Raylib.check_collision_point_rec?(mouse, rec) && Raylib.check_collision_point_rec?(mouse, Ui.rect(x + 16, list_y, panel_w - 32, list_h))
        selected = @picker_selected == index
        Raylib.draw_rectangle_rec(rec, ACCENT) if hovered || selected
        color = (hovered || selected) ? BG : TEXT
        text(entry, rec.x.to_i + 6, ry.to_i + 4, 14, color)
        next unless hovered && mouse_pressed?
        if entry.ends_with?("/")
          @picker_selected = -1
          goto_picker_dir(File.join(@picker_dir, entry))
        else
          @picker_selected = index
        end
      end
      Raylib.end_scissor_mode

      if @picker_entries.empty?
        text("no image files here", x + 26, list_y + 10, 14, MUTED)
      end

      # footer
      selected_name = @picker_selected >= 0 ? @picker_entries[@picker_selected]? : nil
      text(selected_name ? "selected: #{truncate(selected_name, 46)}" : "pick an image, then press Add",
        x + 18, y + panel_h - 40, 13, selected_name ? TEXT : MUTED)

      if button(Ui.rect(x + panel_w - 300, y + panel_h - 44, 130, 30), "Add favourite") && selected_name
        full = File.join(@picker_dir, selected_name)
        Jobs.import_local(full)
        say "queued import of #{selected_name}", OK
        @picker_open = false
      end
      if button(Ui.rect(x + panel_w - 160, y + panel_h - 44, 140, 30), "Cancel")
        @picker_open = false
      end
    end

    def picker_scrolled(viewport_y : Int32, viewport_h : Int32, content_h : Int32) : Float32
      mouse = Raylib.get_mouse_position
      inside = Raylib.check_collision_point_rec?(mouse, Ui.rect(SIDEBAR_W, viewport_y, Raylib.get_screen_width - SIDEBAR_W, viewport_h))
      wheel = inside ? Raylib.get_mouse_wheel_move : 0_f32
      value = wheel == 0_f32 ? @picker_scroll : @picker_scroll - wheel * 60_f32
      value.clamp(0_f32, [0_f32, (content_h - viewport_h).to_f32].max)
    end

    def goto_picker_dir(dir : String) : Nil
      expanded = File.expand_path(dir)
      unless Dir.exists?(expanded)
        say "no such directory: #{expanded}", ERR
        return
      end
      @picker_dir = expanded
      @f_picker_path.value = expanded
      @picker_entries = list_dir(expanded)
      @picker_selected = -1
      @picker_scroll = 0_f32
    end
  end
end
