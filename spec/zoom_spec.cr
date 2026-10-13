require "spec"
require "../src/ui/zoom"

# The crop editor's zoom is anchored: whatever sits under the cursor must not move
# while the zoom changes. These are the arithmetic invariants behind that.
describe Ui::Zoom do
  it "keeps the anchored image point in place (the wheel invariant)" do
    cases = [
      {pan: 0_f32, anchor: 400_f32, centre: 300_f32, ratio: 2_f32},
      {pan: -40_f32, anchor: 120_f32, centre: 300_f32, ratio: 1.6_f32},
      {pan: 75_f32, anchor: 480_f32, centre: 300_f32, ratio: 0.5_f32},
      {pan: 0_f32, anchor: 300_f32, centre: 300_f32, ratio: 3_f32}, # anchor at centre
    ]
    scale = 0.25_f32
    cases.each do |c|
      pan, anchor, centre, ratio = c[:pan], c[:anchor], c[:centre], c[:ratio]
      before = Ui::Zoom.offset_from_centre(pan, anchor, centre, scale)
      after_pan = Ui::Zoom.pan_after_zoom(pan, anchor, centre, ratio)
      after = Ui::Zoom.offset_from_centre(after_pan, anchor, centre, scale * ratio)
      (after - before).abs.should be < 1e-3
    end
  end

  it "leaves the pan alone when the anchor is the centre and zoom is unchanged" do
    Ui::Zoom.pan_after_zoom(37_f32, 300_f32, 300_f32, 1_f32).should be_close 37_f32, 1e-4
  end

  it "scales the pan proportionally for a centre-anchored zoom" do
    # what the slider does: 40 px offset at zoom 1 becomes 80 px at zoom 2
    Ui::Zoom.pan_after_zoom(40_f32, 300_f32, 300_f32, 2_f32).should be_close 80_f32, 1e-4
    # and a centre-anchored zoom is invariant for a point AT the centre
    before = Ui::Zoom.offset_from_centre(40_f32, 300_f32, 300_f32, 0.5_f32)
    after_pan = Ui::Zoom.pan_after_zoom(40_f32, 300_f32, 300_f32, 2_f32)
    after = Ui::Zoom.offset_from_centre(after_pan, 300_f32, 300_f32, 1_f32)
    (after - before).abs.should be < 1e-3
  end

  it "allows no pan while the image exactly fills the crop frame" do
    Ui::Zoom.pan_limit(600_f32, 600_f32).should eq 0_f32
    Ui::Zoom.pan_limit(1000_f32, 600_f32).should be_close 200_f32, 1e-4
    # never negative, even if the frame is somehow larger than the image
    Ui::Zoom.pan_limit(400_f32, 600_f32).should eq 0_f32
  end
end
