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

      if button(Ui.rect(right - 300, 12, 140, 30), "Add all versions")
        add_all_to_theme
      end
      if button(Ui.rect(right - 152, 12, 140, 30), "Refresh")
        refresh_theme_info
        say "theme refreshed", OK
      end

      y = top
      text("your wallpapers for this theme (add target)", left, y, 13, MUTED)
      y += 18
      text(Omarchy.backgrounds_dir, left, y, 13, TEXT)
      y += 20
      text("staging copy, replaced on every theme set", left, y, 12, MUTED)
      y += 16
      text(Omarchy.staged_backgrounds_dir, left, y, 12, MUTED)
      y += 26

      text("monitors", left, y, 13, MUTED)
      y += 18
      @monitors.each do |monitor|
        text("#{monitor.label}  scale #{monitor.scale}  ->  output #{monitor.pixel_width}x#{monitor.pixel_height}", left, y, 14, TEXT)
        y += 18
      end
      y += 14

      # Refresh the listing once a second while this view is open, so deletions and
      # wallpaper changes elsewhere show up without leaving the view.
      refresh_theme_info if @frame % 60 == 0
      entries = @theme_entries
      text("wallpapers in this theme: #{entries.size} · #{entries.count(&.ours)} in your folder", left, y, 14, MUTED)
      y += 22

      list_h = bottom - y
      return if list_h < 80

      gap = 12
      grid_w = right - left
      # Aim for ~232 px cards, then grow them to fill the row exactly. The image
      # area is exactly 16:9 (the inner width, padding excluded) so nothing has to
      # be stretched when it is drawn.
      columns = [1, (grid_w + gap) // (232 + gap)].max
      card_w = (grid_w - gap * (columns + 1)) // columns
      inner_w = card_w - 12
      thumb_h = (inner_w * 9) // 16
      card_h = 6 + thumb_h + 40
      rows = (entries.size + columns - 1) // columns
      content_h = rows * (card_h + gap) + gap
      Raylib.draw_rectangle(left, y, right - left, list_h, PANEL)
      Raylib.draw_rectangle_lines(left, y, right - left, list_h, BORDER)
      @theme_scroll = scroll_for(list_h, content_h, @theme_scroll)

      Raylib.begin_scissor_mode(left, y, right - left, list_h)
      entries.each_with_index do |entry, index|
        col = index % columns
        row = index // columns
        cx = left + gap + col * (card_w + gap)
        cy = y + gap + row * (card_h + gap) - @theme_scroll
        next if cy + card_h < y - card_h || cy > y + list_h
        draw_theme_card(entry, Ui.rect(cx, cy, card_w, card_h))
      end
      Raylib.end_scissor_mode
    end

    # One wallpaper in the theme: thumbnail, name, size, and a guarded delete for
    # the files this app manages.
    def draw_theme_card(entry : Omarchy::BackgroundEntry, rec : Raylib::Rectangle) : Nil
      Raylib.draw_rectangle_rec(rec, CARD)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, BORDER)

      thumb = Ui.rect(rec.x + 6, rec.y + 6, rec.width - 12, rec.height - 46)
      Raylib.draw_rectangle_rec(thumb, BG)
      # Whole-image thumbnails, fitted with their aspect intact (letterboxed).
      if path = @fit_thumbs.fetch(theme_thumb_key(entry), entry.path, nil)
        if tex = texture(path)
          # Contain-fit: never stretch, however different the shapes are.
          dx, dy, dw, dh = Ui::Fit.contain(thumb.x, thumb.y, thumb.width, thumb.height,
            tex.width.to_f32, tex.height.to_f32)
          Raylib.draw_texture_pro(tex, Ui.rect(0, 0, tex.width, tex.height), Ui.rect(dx, dy, dw, dh),
            Raylib::Vector2.new(x: 0_f32, y: 0_f32), 0_f32, Raylib::WHITE)
        end
      else
        text("loading…", thumb.x + 8, thumb.y + thumb.height / 2 - 8, 13, MUTED)
      end

      # Name on its own line (full card width), then size + action, so the name is
      # never overdrawn by the delete chip.
      y = rec.y + rec.height - 40
      text(truncate(entry.name, ((rec.width - 16) / 7.5).to_i32), rec.x + 8, y, 12, entry.ours ? TEXT : MUTED)
      y += 20
      text("#{entry.size // 1024} KiB", rec.x + 8, y + 3, 12, MUTED)

      if entry.ours
        armed = @theme_delete_armed == entry.name
        chip = armed ? (@theme_delete_recoverable ? "confirm" : "confirm *") : "delete"
        if small_button(Ui.rect(rec.x + rec.width - 106, y, 98, 20), chip)
          if armed
            @theme_delete_armed = nil
            delete_theme_file(entry.path, entry.name)
          else
            @theme_delete_armed = entry.name
            # Warning at the moment of deletion: a file the library also holds can
            # be added again, one it does not hold cannot.
            @theme_delete_recoverable = Omarchy.library_copy?(entry.path)
            if @theme_delete_recoverable
              say "press again to delete #{entry.name} from the theme", WARN
            else
              say "#{entry.name} is not in the library — deleting it is permanent", ERR
            end
          end
        end
      else
        text("staging only", rec.x + rec.width - 84, y + 3, 12, MUTED)
      end
    end

    # Shared vertical scroll helper for simple lists.
    def scroll_for(viewport_h : Int32, content_h : Int32, current : Float32) : Float32
      # Same input gate as the buttons: a wheel event from an unfocused window
      # should not scroll anything.
      wheel = input_ready? ? Raylib.get_mouse_wheel_move : 0_f32
      value = wheel == 0_f32 ? current : current - wheel * 60_f32
      value.clamp(0_f32, [0_f32, (content_h - viewport_h).to_f32].max)
    end
  end
end
