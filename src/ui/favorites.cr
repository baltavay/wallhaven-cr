module Ui
  class App
    CARD_W = 300
    CARD_H = 300

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

      if button(Ui.rect(right - 520, 12, 170, 30), "Add all to theme")
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
      rows = (@favorites.size + columns - 1) // columns
      content_h = rows * (CARD_H + gap) + gap
      scroll_bounds(bottom - top, content_h, :fav)
      Raylib.begin_scissor_mode(left, top, right - left, bottom - top)

      @favorites.each_with_index do |wallpaper, index|
        col = index % columns
        row = index // columns
        x = left + col * (CARD_W + gap)
        y = top + gap + row * (CARD_H + gap) - @fav_scroll
        next if y + CARD_H < top - CARD_H || y > bottom
        draw_favorite_card(wallpaper, Ui.rect(x, y, CARD_W, CARD_H))
      end
      Raylib.end_scissor_mode
    end

    def draw_favorite_card(wallpaper : Wallpaper, rec : Raylib::Rectangle) : Nil
      Raylib.draw_rectangle_rec(rec, CARD)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, BORDER)

      thumb = Ui.rect(rec.x + 8, rec.y + 8, rec.width - 16, 150)
      path = @thumbs.fetch("w-#{wallpaper.id}", wallpaper.original_file.try(&.path), wallpaper.remote_thumb)
      if path && (tex = texture(path))
        scale = [thumb.width / tex.width.to_f32, thumb.height / tex.height.to_f32].max
        source = Raylib::Rectangle.new(
          x: (tex.width.to_f32 - thumb.width / scale) / 2,
          y: (tex.height.to_f32 - thumb.height / scale) / 2,
          width: thumb.width / scale,
          height: thumb.height / scale)
        Raylib.draw_texture_pro(tex, source, thumb, Raylib::Vector2.new(x: 0_f32, y: 0_f32), 0_f32, Raylib::WHITE)
      else
        text(wallpaper.downloaded? ? "thumbnailing…" : "no local file", thumb.x.to_i + 10, thumb.y.to_i + 60, 14, MUTED)
      end

      x = rec.x + 10
      y = rec.y + 166
      text(wallpaper.id, x, y, 16, TEXT)
      text(wallpaper.resolution.to_s, x + 160, y + 2, 13, MUTED)
      y += 22
      text(wallpaper.source, x, y, 13, MUTED)

      y += 24
      if button(Ui.rect(x, y, 118, 28), "Add to theme")
        if file = wallpaper.original_file
          file.exists? ? add_to_theme(file.path, theme_name_for(wallpaper)) : say("original file is missing", ERR)
        end
      end
      if button(Ui.rect(x + 124, y, 84, 28), "Edit")
        open_editor(wallpaper)
        @view = View::Editor
      end
      if button(Ui.rect(x + 214, y, 74, 28), "Remove")
        toggle_favorite(wallpaper)
      end

      # cropped versions
      y += 34
      crops = @detail_crops[wallpaper.id]? || [] of WallpaperFile
      text(crops.empty? ? "no versions yet" : "versions:", x, y, 13, crops.empty? ? MUTED : TEXT)
      y += 18
      crops.each do |file|
        text(file.label, x, y + 3, 12, TEXT)
        if small_button(Ui.rect(x + 176, y, 44, 22), "add")
          file.exists? ? add_to_theme(file.path, "#{theme_name_for(wallpaper)}-#{(file.crop_index || 0_i64) + 1}") : say("version file missing", ERR)
        end
        if small_button(Ui.rect(x + 224, y, 64, 22), "delete")
          File.delete(file.path) if File.exists?(file.path)
          Store.delete_file(file.id)
          refresh_favorites
          say "deleted #{File.basename(file.path)}", MUTED
        end
        y += 26
      end
    end

    def scroll_bounds(viewport_h : Int32, content_h : Int32, which : Symbol) : Nil
      wheel = Raylib.get_mouse_wheel_move
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
      copied = 0
      skipped = 0
      @favorites.each do |wallpaper|
        files = Store.files_for(wallpaper.id)
        if files.empty?
          skipped += 1
          next
        end
        files.each do |file|
          next unless file.exists?
          name = if file.kind == "original"
                   theme_name_for(wallpaper)
                 else
                   "#{theme_name_for(wallpaper)}-v#{(file.crop_index || 0_i64) + 1}"
                 end
          begin
            Omarchy.add_background(file.path, name)
            copied += 1
          rescue
            skipped += 1
          end
        end
      end
      refresh_theme_info
      note = skipped > 0 ? ", #{skipped} skipped" : ""
      say "added #{copied} file(s) to #{Omarchy.current_theme_name || "theme"}#{note}", copied > 0 ? OK : WARN
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
