module Ui
  class App
    def draw_theme : Nil
      w = Raylib.get_screen_width
      h = Raylib.get_screen_height
      left = SIDEBAR_W + 16
      top = 52
      right = w - 16
      bottom = h - 36

      text("theme", left, 16, 22, TEXT)
      text(Omarchy.current_theme_name || "none", left + 74, 20, 18, ACCENT)

      if button(Ui.rect(right - 300, 12, 140, 30), "Add favourites")
        add_all_to_theme
      end
      if button(Ui.rect(right - 152, 12, 140, 30), "Refresh")
        refresh_theme_info
        say "theme refreshed", OK
      end

      y = top
      text("staged theme directory", left, y, 13, MUTED)
      y += 18
      text(Omarchy.backgrounds_dir, left, y, 13, TEXT)
      y += 26

      text("monitors", left, y, 13, MUTED)
      y += 18
      @monitors.each do |monitor|
        text("#{monitor.label}  scale #{monitor.scale}  ->  output #{monitor.pixel_width}x#{monitor.pixel_height}", left, y, 14, TEXT)
        y += 18
      end
      y += 14

      backgrounds = Omarchy.backgrounds
      text("backgrounds in this theme: #{backgrounds.size}", left, y, 14, MUTED)
      y += 22

      list_h = bottom - y
      columns = [1, (right - left) // 260].max
      rows = (backgrounds.size + columns - 1) // columns
      content_h = rows * 24 + 10
      Raylib.draw_rectangle(left, y, right - left, list_h, PANEL)
      Raylib.draw_rectangle_lines(left, y, right - left, list_h, BORDER)
      @theme_scroll = scroll_for(list_h, content_h, @theme_scroll)
      Raylib.begin_scissor_mode(left, y, right - left, list_h)
      backgrounds.each_with_index do |name, index|
        col = index % columns
        row = index // columns
        ty = y + 6 + row * 24 - @theme_scroll
        next if ty + 20 < y || ty > y + list_h
        text(truncate(name, 34), left + 10 + col * 260, ty.to_i, 13, TEXT)
      end
      Raylib.end_scissor_mode
    end

    # Shared vertical scroll helper for simple lists.
    def scroll_for(viewport_h : Int32, content_h : Int32, current : Float32) : Float32
      wheel = Raylib.get_mouse_wheel_move
      value = wheel == 0_f32 ? current : current - wheel * 60_f32
      value.clamp(0_f32, [0_f32, (content_h - viewport_h).to_f32].max)
    end
  end
end
