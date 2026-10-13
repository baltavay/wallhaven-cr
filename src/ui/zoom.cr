# Zoom/pan arithmetic for the crop editor.
#
# Deliberately dependency-free (plain floats, no raylib) so the invariant can be
# tested directly: while the zoom changes by `ratio`, the image point under the
# anchor must not move.
#
# Geometry being described, in screen pixels:
#
#   image centre  = frame centre + pan
#   a screen position s shows the image offset (s - frame centre - pan) / scale
#
# from the image's centre, where `scale = fit_scale * zoom`. For the point under
# `anchor` to stay put, its offset before and after must be equal:
#
#   (anchor - centre - pan0) / scale0 == (anchor - centre - pan1) / scale1
#
# with scale1 = scale0 * ratio, which solves to `pan_after_zoom`.
module Ui::Zoom
  # Pan that keeps whatever sits under `anchor` (screen x or y) in place while the
  # zoom is multiplied by `ratio`. `centre` is the frame centre (the crop window's
  # midpoint), so passing `anchor == centre` gives the plain centre-anchored zoom.
  def self.pan_after_zoom(pan : Float32, anchor : Float32, centre : Float32, ratio : Float32) : Float32
    anchor - centre - (anchor - centre - pan) * ratio
  end

  # Offset of the image point shown at `screen`, measured from the image's centre
  # in image pixels. The anchor invariant is "this value does not change".
  def self.offset_from_centre(pan : Float32, screen : Float32, centre : Float32, scale : Float32) : Float32
    return 0_f32 if scale == 0_f32
    (screen - centre - pan) / scale
  end

  # Clamp that keeps the crop frame inside the image: the image may not be dragged
  # so far that the frame leaves it.
  def self.pan_limit(image_extent : Float32, frame_extent : Float32) : Float32
    ((image_extent - frame_extent) / 2_f32).clamp(0_f32, Float32::MAX)
  end
end
