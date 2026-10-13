# Fitting an image into a box without distorting it.
#
# Dependency-free (plain floats) so the aspect guarantee can be tested directly:
# a thumbnail must never be stretched, however different the source and the box
# shapes are — a 2.26:1 wallpaper in a 16:9 card gets bars, not a squashed image.
module Ui::Fit
  # Contain: scale the image until it just fits inside the box, centred. Bars take
  # the leftover space on one axis only.
  #
  # Returns {x, y, width, height} for the drawn image.
  def self.contain(box_x : Float32, box_y : Float32, box_w : Float32, box_h : Float32,
                   tex_w : Float32, tex_h : Float32) : Tuple(Float32, Float32, Float32, Float32)
    return {box_x, box_y, 0_f32, 0_f32} if box_w <= 0_f32 || box_h <= 0_f32 || tex_w <= 0_f32 || tex_h <= 0_f32

    scale = [box_w / tex_w, box_h / tex_h].min
    width = tex_w * scale
    height = tex_h * scale
    {box_x + (box_w - width) / 2_f32, box_y + (box_h - height) / 2_f32, width, height}
  end
end
