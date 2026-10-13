require "spec"
require "../src/ui/fit"

# Thumbnails must never be stretched: whatever the source shape, the drawn
# rectangle must keep the source's aspect ratio, with the leftover space as bars.
describe Ui::Fit do
  it "fills the box exactly when the shapes match" do
    x, y, w, h = Ui::Fit.contain(10_f32, 20_f32, 320_f32, 180_f32, 640_f32, 360_f32)
    {x, y, w, h}.should eq({10_f32, 20_f32, 320_f32, 180_f32})
  end

  it "letterboxes a wider source with equal top and bottom bars" do
    # a 2.264:1 wallpaper in a 16:9 box
    box_h = 180_f32
    x, y, w, h = Ui::Fit.contain(0_f32, 0_f32, 320_f32, box_h, 640_f32, 282.7_f32)
    w.should be_close 320_f32, 1e-3
    h.should be_close 320_f32 / 2.26415_f32, 0.5_f32
    y.should be_close (box_h - h) / 2_f32, 1e-3
    x.should be_close 0_f32, 1e-3
  end

  it "pillarboxes a taller source with equal left and right bars" do
    box_w = 320_f32
    x, y, w, h = Ui::Fit.contain(0_f32, 0_f32, box_w, 180_f32, 1000_f32, 2000_f32)
    h.should be_close 180_f32, 1e-3
    w.should be_close 90_f32, 1e-3
    x.should be_close (box_w - w) / 2_f32, 1e-3
  end

  it "keeps the source aspect for a range of shapes" do
    [{4000_f32, 3000_f32}, {1920_f32, 1080_f32}, {1080_f32, 1920_f32}, {5905_f32, 3000_f32}].each do |pair|
      tex_w, tex_h = pair
      _, _, w, h = Ui::Fit.contain(0_f32, 0_f32, 320_f32, 180_f32, tex_w, tex_h)
      (w / h).should be_close(tex_w / tex_h, 1e-3)
      w.should be <= 320_f32
      h.should be <= 180_f32
    end
  end

  it "draws nothing for a degenerate box or texture" do
    Ui::Fit.contain(5_f32, 5_f32, 0_f32, 100_f32, 100_f32, 100_f32).should eq({5_f32, 5_f32, 0_f32, 0_f32})
    Ui::Fit.contain(5_f32, 5_f32, 100_f32, 100_f32, 0_f32, 100_f32).should eq({5_f32, 5_f32, 0_f32, 0_f32})
  end
end
