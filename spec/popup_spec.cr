require "spec"
require "../src/ui/popup"

# A popup opens from a control click, so the click that opened it is still
# "pressed" in the same frame and it lands on the control — the keep-open region
# must therefore include the control, or the popup closes instantly.
describe Ui::Popup do
  it "places the panel just below its anchor" do
    anchor = Raylib::Rectangle.new(x: 240_f32, y: 170_f32, width: 44_f32, height: 28_f32)
    panel = Ui::Popup.below(anchor, 224_f32, 224_f32, 6_f32, 1920_f32)
    panel.x.should eq 240_f32
    panel.y.should eq 204_f32 # 170 + 28 + 6
    panel.width.should eq 224_f32
  end

  it "keeps the panel on screen when the anchor is near the right edge" do
    anchor = Raylib::Rectangle.new(x: 1900_f32, y: 10_f32, width: 44_f32, height: 28_f32)
    panel = Ui::Popup.below(anchor, 224_f32, 224_f32, 6_f32, 1920_f32)
    panel.x.should be <= 1920_f32 - 224_f32
    panel.x.should be >= 0_f32
  end

  it "counts a click on the anchor as inside, and a click beside the popup as outside" do
    anchor = Raylib::Rectangle.new(x: 240_f32, y: 170_f32, width: 44_f32, height: 28_f32)
    panel = Ui::Popup.below(anchor, 224_f32, 224_f32, 6_f32, 1920_f32)
    region = Ui::Popup.region(anchor, panel)

    # the opening click: in the middle of the swatch
    Raylib.check_collision_point_rec?(Raylib::Vector2.new(x: 262_f32, y: 184_f32), region).should be_true
    # inside the panel
    Raylib.check_collision_point_rec?(Raylib::Vector2.new(x: 300_f32, y: 300_f32), region).should be_true
    # well away from either
    Raylib.check_collision_point_rec?(Raylib::Vector2.new(x: 700_f32, y: 500_f32), region).should be_false
    # the region spans anchor top to panel bottom
    region.y.should eq anchor.y
    (region.y + region.height).should eq(panel.y + panel.height)
  end
end
