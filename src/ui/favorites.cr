module Ui
  class App
    CARD_W = 300
    FAV_THUMB_H = (CARD_W - 16) * 9_f32 / 16_f32
    # Card geometry, relative to the card's top-left corner; the card grows by one
    # row per version so every version is visible and selectable.
    FAV_ROWS_TOP   = 236_f32
    FAV_ACTION_H   = 26_f32
    FAV_BOTTOM_PAD = 8_f32

    # Height a wallpaper's card needs to show all of its versions.
    def fav_card_height(wallpaper : Wallpaper) : Float32
      rows = [wallpaper.files.size, 1].max
      FAV_ROWS_TOP + rows * VERSION_ROW_H + 6_f32 + FAV_ACTION_H + FAV_BOTTOM_PAD
    end

    def draw_favorites : Nil
      w = Raylib.get_screen_width
      h = Raylib.get_screen_height
      top = 64
      left = SIDEBAR_W + 16
      right = w - 16
      bottom = h - 36

      text("favourites", left, 16, 22, TEXT)
      # On its own line: at a tiled window width there is no room for a summary
      # beside the title and the three buttons.
      text("#{@favorites.size} entries · #{Omarchy.current_theme_name || "no theme"}", left, 44, 13, MUTED)

      # Explicit: this one copies every version of every favourite, unlike the
      # per-card button which copies the version you selected.
      if button(Ui.rect(right - 520, 12, 170, 30), "Add all versions")
        add_all_to_theme
      end
      if button(Ui.rect(right - 342, 12, 160, 30), "Add local file…")
        open_picker
      end
      if button(Ui.rect(right - 174, 12, 158, 30), "Refresh")
        refresh_favorites
        say "favourites reloaded", OK
      end

      if @favorites.empty?
        text("no favourites yet — search wallhaven or add a local file", left, top + 20, 17, MUTED)
        return
      end

      gap = 14
      columns = [1, (right - left + gap) // (CARD_W + gap)].max
      # Cards in a row share the height of the tallest, so a card with several
      # versions does not overlap its neighbour.
      heights = @favorites.map { |wallpaper| fav_card_height(wallpaper) }
      row_heights = [] of Float32
      index = 0
      while index < heights.size
        row_heights << heights[index, columns].max
        index += columns
      end
      content_h = (row_heights.sum + row_heights.size * gap + gap).to_i32
      scroll_bounds(bottom - top, content_h, :fav)
      Raylib.begin_scissor_mode(left, top, right - left, bottom - top)

      @favorites.each_with_index do |wallpaper, index|
        col = index % columns
        row = index // columns
        row_top = row_heights[0, row].sum + row * gap
        x = left + col * (CARD_W + gap)
        y = top + gap + row_top - @fav_scroll
        card_h = row_heights[row]
        next if y + card_h < top - card_h || y > bottom
        draw_favorite_card(wallpaper, Ui.rect(x, y, CARD_W, card_h))
      end
      Raylib.end_scissor_mode
    end

    def draw_favorite_card(wallpaper : Wallpaper, rec : Raylib::Rectangle) : Nil
      Raylib.draw_rectangle_rec(rec, CARD)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, BORDER)

      # Whole wallpaper, aspect preserved: the image area is 16:9, like a desktop
      # wallpaper, so a 16:9 source fills it exactly and anything else letterboxes.
      thumb = Ui.rect(rec.x + 8, rec.y + 8, rec.width - 16, FAV_THUMB_H)
      original = wallpaper.original_file
      path = @fit_thumbs.fetch(fit_thumb_key(wallpaper, original), original.try(&.path), wallpaper.remote_fit_thumb)
      if path && (tex = texture(path))
        dx, dy, dw, dh = Ui::Fit.contain(thumb.x, thumb.y, thumb.width, thumb.height,
          tex.width.to_f32, tex.height.to_f32)
        Raylib.draw_texture_pro(tex, Ui.rect(0, 0, tex.width, tex.height), Ui.rect(dx, dy, dw, dh),
          Raylib::Vector2.new(x: 0_f32, y: 0_f32), 0_f32, Raylib::WHITE)
      else
        text(wallpaper.downloaded? ? "thumbnailing…" : "no local file", thumb.x.to_i + 10, thumb.y.to_i + 60, 14, MUTED)
      end

      x = rec.x + 10
      y = rec.y + 176
      text(wallpaper.id, x, y, 16, TEXT)
      text(wallpaper.resolution.to_s, x + 160, y + 2, 13, MUTED)
      y += 22
      text(wallpaper.source, x, y, 13, MUTED)

      # Versions first, then the action: read it as "pick a version, then add it".
      # The button names the chosen version so there is nothing to guess.
      y += 22
      files = wallpaper.files
      if files.empty?
        text("no local versions yet", x, y, 12, MUTED)
        return
      end
      text("version to use:", x, y, 13, TEXT)
      y += 16
      # The card is sized to fit every version (see fav_card_height), so nothing is
      # held back here.
      y = version_rows(wallpaper, files, x.to_f32, y.to_f32, (rec.width - 20).to_f32, allow_delete: true).to_i32
      y += 6

      chosen = chosen_file(wallpaper)
      present = chosen && in_theme?(wallpaper, chosen)
      if button(Ui.rect(x, y, 118, 26), present ? "In theme" : "Add #{chosen_label(wallpaper)}")
        add_chosen_to_theme(wallpaper)
      end
      if button(Ui.rect(x + 124, y, 84, 26), "Edit")
        open_editor(wallpaper)
        @view = View::Editor
      end
      if button(Ui.rect(x + 214, y, 74, 26), "Remove")
        toggle_favorite(wallpaper)
      end
    end

    # One selectable row per version: the radio picks it for "Add to theme", the
    # chip adds that very version right away.
    def version_rows(wallpaper : Wallpaper, files : Array(WallpaperFile), x : Float32, y : Float32, width : Float32, allow_delete : Bool) : Float32
      selected = chosen_index(wallpaper)
      mouse = Raylib.get_mouse_position
      files.each_with_index do |file, index|
        row = Ui.rect(x, y, width, 22)
        on = index == selected
        if Raylib.check_collision_point_rec?(mouse, row) && mouse_pressed?
          set_chosen_index(wallpaper, index)
          on = true
        end
        # radio dot + label
        Raylib.draw_circle((x + 7).to_i, (y + 11).to_i, 5, on ? ACCENT : BORDER)
        Raylib.draw_circle((x + 7).to_i, (y + 11).to_i, 2, on ? BG : PANEL)
        text(file.label, x + 18, y + 3, 12, file.exists? ? (on ? TEXT : MUTED) : ERR)
        # right-hand actions
        chip_x = x + width - (allow_delete && file.kind == "crop" ? 116 : 62)
        present = in_theme?(wallpaper, file)
        if small_button(Ui.rect(chip_x, y, 68, 20), present ? "remove" : "add")
          if present
            remove_version_from_theme(wallpaper, file)
          elsif file.exists?
            add_version_to_theme(wallpaper, file)
          else
            say("version file missing", ERR)
          end
        end
        if allow_delete && file.kind == "crop"
          if small_button(Ui.rect(chip_x + 72, y, 40, 20), "del")
            File.delete(file.path) if File.exists?(file.path)
            Store.delete_file(file.id)
            refresh_favorites
            say "deleted #{File.basename(file.path)}", MUTED
          end
        end
        y += VERSION_ROW_H
      end
      y
    end

    def scroll_bounds(viewport_h : Int32, content_h : Int32, which : Symbol) : Nil
      # Same input gate as the buttons: a wheel event from an unfocused window
      # should not scroll anything.
      wheel = input_ready? ? Raylib.get_mouse_wheel_move : 0_f32
      max = [0_f32, (content_h - viewport_h).to_f32].max
      case which
      when :fav
        @fav_scroll -= wheel * 60_f32 if wheel != 0_f32
        @fav_scroll = @fav_scroll.clamp(0_f32, max)
      when :queue
        @queue_scroll -= wheel * 60_f32 if wheel != 0_f32
        @queue_scroll = @queue_scroll.clamp(0_f32, max)
      end
    end

    # Copy every downloaded favourite (original + its cropped versions) into the
    # current Omarchy theme's backgrounds directory.
    def add_all_to_theme : Nil
      refresh_favorites
      added = 0
      already = 0
      skipped = 0
      @favorites.each do |wallpaper|
        files = Store.files_for(wallpaper.id)
        if files.empty?
          skipped += 1
          next
        end
        files.each do |file|
          next unless file.exists?
          crop = file.kind == "crop" ? file.crop_index : nil
          name = Omarchy.version_name(theme_stem(wallpaper), file.path, crop)
          begin
            # Identity is the content: the same version is never copied twice.
            if Omarchy.add_background(file.path, name).added?
              added += 1
            else
              already += 1
            end
          rescue
            skipped += 1
          end
        end
      end
      refresh_theme_info
      parts = ["#{added} added"]
      parts << "#{already} already there" if already > 0
      parts << "#{skipped} skipped (not downloaded)" if skipped > 0
      say "#{parts.join(", ")} — #{Omarchy.current_theme_name || "theme"}", added > 0 ? OK : MUTED
    end

    # Load crop lists for the favourites grid (cached, refreshed with the grid).
    def refresh_detail_crops : Nil
      result = {} of String => Array(WallpaperFile)
      @favorites.each do |wallpaper|
        result[wallpaper.id] = Store.files_for(wallpaper.id).select { |f| f.kind == "crop" }
      end
      @detail_crops = result
    end
  end
end
