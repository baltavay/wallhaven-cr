module Ui
  class App
    def draw_queue : Nil
      w = Raylib.get_screen_width
      h = Raylib.get_screen_height
      left = SIDEBAR_W + 16
      top = 52
      right = w - 16
      bottom = h - 36
      list_h = bottom - top

      text("downloads", left, 16, 22, TEXT)
      counts = safe_counts
      line = fitted(
        "queued #{counts["queued"]} · running #{counts["running"]} · done #{counts["succeeded"]} · failed #{counts["failed"]}",
        "q#{counts["queued"]} r#{counts["running"]} d#{counts["succeeded"]} f#{counts["failed"]}",
        (right - 430 - left - 120).to_f32)
      text(line, left + 110, 22, 15, MUTED) if line

      if button(Ui.rect(right - 420, 12, 130, 30), "Refresh")
        say "queue refreshed", OK
      end
      if button(Ui.rect(right - 282, 12, 130, 30), "Retry failed")
        retry_failed
      end
      if button(Ui.rect(right - 144, 12, 130, 30), "Clear finished")
        clear_finished
      end

      jobs = Jobs.recent(60)
      list_w = (right - left) * 3 // 5
      row_h = 46
      scroll_bounds(list_h, jobs.size * row_h + 10, :queue)

      Raylib.draw_rectangle(left, top, list_w, list_h, PANEL)
      Raylib.draw_rectangle_lines(left, top, list_w, list_h, BORDER)
      Raylib.begin_scissor_mode(left, top, list_w, list_h)
      if jobs.empty?
        text("nothing queued yet", left + 14, top + 14, 16, MUTED)
      end
      jobs.each_with_index do |job, index|
        y = top + 8 + index * row_h - @queue_scroll
        next if y + row_h < top - row_h || y > top + list_h
        color = job_color(job.status)
        Raylib.draw_rectangle(left + 8, y, list_w - 16, row_h - 6, CARD)
        Raylib.draw_rectangle(left + 8, y, 3, row_h - 6, color)
        text("##{job.id} #{job.kind}", left + 20, y + 6, 15, TEXT)
        text(job.status, left + list_w - 110, y + 6, 14, color)
        detail = job.error || job.note || job.result || ""
        text(truncate(detail, 78), left + 20, y + 24, 12, job.error ? ERR : MUTED)
      end
      Raylib.end_scissor_mode

      log_x = left + list_w + 12
      log_w = right - log_x
      Raylib.draw_rectangle(log_x, top, log_w, list_h, PANEL)
      Raylib.draw_rectangle_lines(log_x, top, log_w, list_h, BORDER)
      text("worker log", log_x + 12, top + 8, 14, MUTED)
      Raylib.begin_scissor_mode(log_x, top + 30, log_w, list_h - 36)
      lines = Jobs.log_lines
      lines.last([1, (list_h - 40) // 18].max).each_with_index do |line, index|
        text(truncate(line, 74), log_x + 12, top + 32 + index * 18, 13, TEXT)
      end
      Raylib.end_scissor_mode
    end

    def job_color(status : String) : Raylib::Color
      case status
      when "succeeded" then OK
      when "failed"    then ERR
      when "running"   then WARN
      else                  MUTED
      end
    end

    def truncate(text : String, limit : Int32) : String
      return text if text.size <= limit
      text[0, limit - 1] + "…"
    end

    def retry_failed : Nil
      n = Db.conn.exec("UPDATE jobs SET status = 'queued', attempts = 0, error = NULL WHERE status = 'failed'").rows_affected
      say "requeued #{n} failed job(s)", n > 0 ? OK : MUTED
    end

    def clear_finished : Nil
      n = Db.conn.exec("DELETE FROM jobs WHERE status = 'succeeded'").rows_affected
      say "cleared #{n} finished job(s)", MUTED
    end
  end
end
