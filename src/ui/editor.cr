module Ui
  class App
    def open_editor(wallpaper : Wallpaper) : Nil
      @editor_wallpaper = wallpaper
      @editor_source = wallpaper.original_file || Store.files_for(wallpaper.id).first?
      @editor_zoom = 1_f32
      @editor_pan = Raylib::Vector2.new(x: 0_f32, y: 0_f32)
      @editor_preview_dims = nil
      @editor_versions = Store.files_for(wallpaper.id)
      @editor_crop_rect = nil
      if source = @editor_source
        @previews.fetch("preview-#{source.id}", source.path, nil)
      end
      unless @monitors.any? { |m| m.name == @editor_target }
        @editor_target = (@monitors.first? || Monitors::FALLBACK).name
      end
    end

    def draw_editor : Nil
      w = Raylib.get_screen_width
      h = Raylib.get_screen_height
      left = SIDEBAR_W + 16
      top = 52
      right = w - 16
      bottom = h - 36
      panel_w = 300

      text("crop editor", left, 16, 22, TEXT)

      unless wallpaper = @editor_wallpaper
        text("select a wallpaper in Browse, then press Open crop editor", left, top + 20, 17, MUTED)
        return
      end

      view = Ui.rect(left, top, right - left - panel_w - 12, bottom - top)
      Raylib.draw_rectangle_rec(view, PANEL)
      draw_editor_canvas(view, wallpaper)
      draw_editor_panel(Ui.rect(right - panel_w, top, panel_w, bottom - top), wallpaper)
    end

    # Geometry shared by drawing and by the crop job.
    private def editor_geometry(view : Raylib::Rectangle, source : WallpaperFile)
      pw, ph = @editor_preview_dims || {source.width.to_i32, source.height.to_i32}
      pw = 1 if pw < 1
      ph = 1 if ph < 1
      target = current_monitor
      out_w = target.pixel_width
      out_h = target.pixel_height
      aspect = out_w.to_f32 / out_h.to_f32

      inset = 24_f32
      frame_w = [(view.width - inset * 2), ((view.height - inset * 2) * aspect)].min
      frame_h = frame_w / aspect
      frame = Ui.rect(view.x + (view.width - frame_w) / 2, view.y + (view.height - frame_h) / 2, frame_w, frame_h)

      base = [frame_w / pw, frame_h / ph].min
      min_zoom = [frame_w / (pw * base), frame_h / (ph * base)].max
      @editor_zoom = @editor_zoom.clamp(min_zoom, 12_f32)
      @editor_min_zoom = min_zoom
      scale = base * @editor_zoom

      img_w = pw * scale
      img_h = ph * scale
      limit_x = [0_f32, (img_w - frame_w) / 2].max
      limit_y = [0_f32, (img_h - frame_h) / 2].max
      @editor_pan = Raylib::Vector2.new(
        x: @editor_pan.x.clamp(-limit_x, limit_x),
        y: @editor_pan.y.clamp(-limit_y, limit_y))

      img_x = frame.x + (frame_w - img_w) / 2 + @editor_pan.x
      img_y = frame.y + (frame_h - img_h) / 2 + @editor_pan.y

      sx = (frame.x - img_x) / scale
      sy = (frame.y - img_y) / scale
      sw = frame_w / scale
      sh = frame_h / scale
      {
        frame: frame,
        image: Ui.rect(img_x, img_y, img_w, img_h),
        scale: scale,
        preview: {pw, ph},
        source_rect: {sx, sy, sw, sh},
        out: {out_w, out_h},
        target: target,
      }
    end

    @editor_min_zoom : Float32 = 1_f32

    # Multiply the zoom by `factor`, keeping the image point under `anchor` (screen
    # coordinates) exactly where it is. Public so it can be driven in checks — the
    # wheel is the only caller in normal use.
    def editor_zoom_at(anchor : Raylib::Vector2, factor : Float32) : Nil
      @editor_zoom_wanted = (@editor_zoom * factor).clamp(@editor_min_zoom, 12_f32)
      @editor_zoom_anchor = anchor
      apply_pending_zoom
    end

    # Zoom changes are applied here, before the geometry is rebuilt, because the
    # anchor correction needs the frame centre from the previous geometry: the
    # pan must move by exactly the amount that keeps the anchored image point in
    # place (see Ui::Zoom).
    private def apply_pending_zoom : Nil
      wanted = @editor_zoom_wanted
      anchor = @editor_zoom_anchor
      if wanted.nil?
        # The zoom slider writes `@editor_zoom` directly; treat any change since
        # the last geometry as a centre-anchored zoom.
        return if @editor_zoom == @editor_zoom_applied
        wanted = @editor_zoom
      end
      from = @editor_zoom_applied
      return if from <= 0_f32

      ratio = wanted.not_nil! / from
      if frame = @editor_frame
        cx = frame.x + frame.width / 2
        cy = frame.y + frame.height / 2
        if at = anchor
          # wheel: the cursor keeps looking at the same image point
          @editor_pan = Raylib::Vector2.new(
            x: Ui::Zoom.pan_after_zoom(@editor_pan.x, at.x, cx, ratio),
            y: Ui::Zoom.pan_after_zoom(@editor_pan.y, at.y, cy, ratio))
        else
          # slider: no cursor, so anchor the crop window's centre
          @editor_pan = Raylib::Vector2.new(
            x: Ui::Zoom.pan_after_zoom(@editor_pan.x, cx, cx, ratio),
            y: Ui::Zoom.pan_after_zoom(@editor_pan.y, cy, cy, ratio))
        end
      end
      @editor_zoom = wanted.not_nil!
      @editor_zoom_applied = @editor_zoom
      @editor_zoom_wanted = nil
      @editor_zoom_anchor = nil
    end

    def draw_editor_canvas(view : Raylib::Rectangle, wallpaper : Wallpaper) : Nil
      source = @editor_source
      unless source && source.exists?
        text("no local original — download it first", view.x.to_i + 20, view.y.to_i + 20, 16, WARN)
        return
      end
      preview = @previews.fetch("preview-#{source.id}", source.path, nil)
      unless preview && File.exists?(preview)
        text("building preview…", view.x.to_i + 20, view.y.to_i + 20, 16, MUTED)
        return
      end
      if @editor_preview_dims.nil?
        begin
          pw, ph = ImageOps.identify(preview)
          @editor_preview_dims = {pw.to_i32, ph.to_i32}
        rescue
        end
      end

      apply_pending_zoom
      geometry = editor_geometry(view, source)
      frame = geometry[:frame]
      image = geometry[:image]
      @editor_frame = frame
      @editor_zoom_applied = @editor_zoom

      # Remember the mapping so "Create version" uses exactly what was shown.
      sx, sy, sw, sh = geometry[:source_rect]
      pw, ph = geometry[:preview]
      kx = source.width.to_f32 / pw
      ky = source.height.to_f32 / ph
      out_w, out_h = geometry[:out]
      @editor_crop_rect = {
        x: (sx * kx).round.to_i64.clamp(0_i64, source.width),
        y: (sy * ky).round.to_i64.clamp(0_i64, source.height),
        w: (sw * kx).round.to_i64,
        h: (sh * ky).round.to_i64,
        out_w: out_w,
        out_h: out_h,
        target: geometry[:target].name,
      }

      Raylib.begin_scissor_mode(view.x.to_i, view.y.to_i, view.width.to_i, view.height.to_i)
      if tex = texture(preview)
        Raylib.draw_texture_pro(tex, Ui.rect(0, 0, tex.width, tex.height), image,
          Raylib::Vector2.new(x: 0_f32, y: 0_f32), 0_f32, Raylib::WHITE)
      end
      # dim everything outside the crop frame
      shade = Raylib::Color.new(r: 0, g: 0, b: 0, a: 170)
      Raylib.draw_rectangle(view.x.to_i, view.y.to_i, view.width.to_i, (frame.y - view.y).to_i, shade)
      Raylib.draw_rectangle(view.x.to_i, (frame.y + frame.height).to_i, view.width.to_i,
        (view.y + view.height - frame.y - frame.height).to_i, shade)
      Raylib.draw_rectangle(view.x.to_i, frame.y.to_i, (frame.x - view.x).to_i, frame.height.to_i, shade)
      Raylib.draw_rectangle((frame.x + frame.width).to_i, frame.y.to_i,
        (view.x + view.width - frame.x - frame.width).to_i, frame.height.to_i, shade)
      Raylib.end_scissor_mode

      Raylib.draw_rectangle_lines_ex(frame, 2_f32, ACCENT)
      # rule of thirds
      3.times do |i|
        next if i == 0
        gx = frame.x + frame.width * i / 3
        gy = frame.y + frame.height * i / 3
        Raylib.draw_line(gx.to_i, frame.y.to_i, gx.to_i, (frame.y + frame.height).to_i, Raylib::Color.new(r: 122, g: 162, b: 247, a: 90))
        Raylib.draw_line(frame.x.to_i, gy.to_i, (frame.x + frame.width).to_i, gy.to_i, Raylib::Color.new(r: 122, g: 162, b: 247, a: 90))
      end

      # interaction: wheel zooms about the cursor, drag pans
      mouse = Raylib.get_mouse_position
      inside = Raylib.check_collision_point_rec?(mouse, view)
      if input_ready? && inside && (steps = Raylib.get_mouse_wheel_move) != 0_f32
        editor_zoom_at(mouse, 1_f32 + steps * 0.12_f32)
      end
      if mouse_pressed? && inside
        @editor_dragging = true
      end
      if mouse_released?
        @editor_dragging = false
      end
      if @editor_dragging
        delta = Raylib.get_mouse_delta
        @editor_pan = Raylib::Vector2.new(x: @editor_pan.x + delta.x, y: @editor_pan.y + delta.y)
      end
    end

    def draw_editor_panel(rec : Raylib::Rectangle, wallpaper : Wallpaper) : Nil
      Raylib.draw_rectangle_rec(rec, PANEL)
      Raylib.draw_rectangle_lines_ex(rec, 1_f32, BORDER)
      x = rec.x + 14
      w = rec.width - 28
      y = rec.y + 14

      text(wallpaper.id, x, y, 18, TEXT)
      y += 24
      text("#{wallpaper.resolution} · #{wallpaper.source}", x, y, 13, MUTED)
      y += 26

      text("target monitor", x, y, 13, MUTED)
      y += 18
      names = @monitors.map(&.label)
      @editor_monitor = @monitors.index { |m| m.name == @editor_target } || 0
      dropdown(Ui.rect(x, y, w, 28), names.empty? ? "fallback" : names.join(";"), pointerof(@editor_monitor), pointerof(@drop_monitor))
      # The list is drawn in the overlay pass and writes the index directly, so the
      # target is derived from it every frame rather than on a change event.
      target_monitor = @monitors[@editor_monitor]? || Monitors::FALLBACK
      @editor_target = target_monitor.name
      y += 36

      target = current_monitor
      text("output #{target.pixel_width}x#{target.pixel_height}", x, y, 14, OK)
      y += 22
      text("source #{(@editor_source.try(&.width) || 0).to_i}x#{(@editor_source.try(&.height) || 0).to_i}", x, y, 13, MUTED)
      y += 26

      text("zoom", x, y, 13, MUTED)
      y += 18
      Raygui.slider_bar(Ui.rect(x, y, w, 24), nil, nil, pointerof(@editor_zoom), @editor_min_zoom, 12_f32)
      y += 32
      text("drag the image to choose the area", x, y, 12, MUTED)
      y += 22
      if button(Ui.rect(x, y, w, 30), "Create version")
        create_version(wallpaper)
      end
      y += 36
      if button(Ui.rect(x, y, w, 28), "Reset view")
        @editor_zoom = 1_f32
        @editor_pan = Raylib::Vector2.new(x: 0_f32, y: 0_f32)
      end
      y += 36

      # Add the version currently open in the editor (the source of the crop) to the
      # theme without leaving this view.
      if source = @editor_source
        present = in_theme?(wallpaper, source)
        if button(Ui.rect(x, y, w, 30), present ? "In theme" : "Add #{source.label} to theme")
          if present
            remove_version_from_theme(wallpaper, source)
          elsif source.exists?
            add_version_to_theme(wallpaper, source)
          else
            say("version file missing", ERR)
          end
        end
      end
      y += 40
      Raylib.draw_line(x, y, x + w, y, BORDER)
      y += 12

      text("versions", x, y, 15, TEXT)
      y += 22
      @editor_versions = Store.files_for(wallpaper.id) if @frame % 30 == 0
      if @editor_versions.empty?
        text("none yet", x, y, 13, MUTED)
      end
      @editor_versions.each do |file|
        deletable = file.kind == "crop"
        chip_w = deletable ? 74_f32 : 0_f32
        text(truncate(file.label, deletable ? 18 : 26), x, y, 13, file.exists? ? TEXT : ERR)
        present = in_theme?(wallpaper, file)
        if small_button(Ui.rect(x + w - chip_w - 62, y - 3, 58, 22), present ? "remove" : "add")
          if present
            remove_version_from_theme(wallpaper, file)
          elsif file.exists?
            add_version_to_theme(wallpaper, file)
          else
            say("version file missing", ERR)
          end
        end
        if deletable
          if small_button(Ui.rect(x + w - 60, y - 3, 60, 22), "delete")
            File.delete(file.path) if File.exists?(file.path)
            Store.delete_file(file.id)
            @editor_versions = Store.files_for(wallpaper.id)
            refresh_favorites
            say "deleted #{File.basename(file.path)}", MUTED
          end
        end
        y += 26
      end
    end

    def current_monitor : Monitors::Monitor
      @monitors.find { |m| m.name == @editor_target } || @monitors.first? || Monitors::FALLBACK
    end

    def create_version(wallpaper : Wallpaper) : Nil
      source = @editor_source
      unless source && source.exists?
        return say "download the original first", WARN
      end
      crop = @editor_crop_rect
      return say "preview not ready yet", WARN unless crop

      x = crop[:x]
      y = crop[:y]
      w = crop[:w].clamp(1_i64, source.width - x)
      h = crop[:h].clamp(1_i64, source.height - y)

      Jobs.crop(wallpaper.id, source.id, x, y, w, h, crop[:out_w], crop[:out_h],
        "#{crop[:target]} #{crop[:out_w]}x#{crop[:out_h]}")
      say "queued version #{crop[:out_w]}x#{crop[:out_h]} for #{crop[:target]}", OK
    end
  end
end
