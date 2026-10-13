require "raylib-cr"

# Placement and hit region for popups anchored to a control (dropdown lists, the
# colour picker).
#
# Two rules matter, and both were got wrong once:
#
#   * the panel appears *below* its anchor, clamped to the screen;
#   * the keep-open region is the union of the anchor and the panel, because the
#     click that opened the popup is still "pressed" in the same frame and it
#     landed on the anchor — without the anchor in the region the popup opened and
#     closed in a single frame.
module Ui::Popup
  def self.below(anchor : Raylib::Rectangle, width : Float32, height : Float32,
                 gap : Float32, screen_width : Float32) : Raylib::Rectangle
    x = anchor.x.clamp(0_f32, [0_f32, screen_width - width - 4_f32].max)
    Raylib::Rectangle.new(x: x, y: anchor.y + anchor.height + gap, width: width, height: height)
  end

  def self.region(anchor : Raylib::Rectangle, panel : Raylib::Rectangle) : Raylib::Rectangle
    x = [anchor.x, panel.x].min
    y = [anchor.y, panel.y].min
    right = [anchor.x + anchor.width, panel.x + panel.width].max
    bottom = [anchor.y + anchor.height, panel.y + panel.height].max
    Raylib::Rectangle.new(x: x, y: y, width: right - x, height: bottom - y)
  end
end
