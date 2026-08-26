"""Generate the Talia Exporter app icon.

Kept in-repo so the icon is reproducible and reviewable rather than a binary
someone dropped in once. Palette is lifted from DesignSystem/TaliaTheme.swift
(taliaNavy / taliaBlue) so the icon matches the app it launches.

App Store rules the output has to satisfy:
  * exactly 1024x1024
  * NO alpha channel (an icon with transparency is rejected at upload)
  * square and unrounded — iOS applies the superellipse mask itself

    python3 tools/make_app_icon.py
"""

from PIL import Image, ImageDraw

SIZE = 1024
NAVY = (51, 77, 133)     # Color.taliaNavy
BLUE = (91, 135, 229)    # Color.taliaBlue
WHITE = (255, 255, 255)


def _gradient() -> Image.Image:
    """Diagonal navy -> blue wash."""
    base = Image.new("RGB", (SIZE, SIZE), NAVY)
    pixels = base.load()
    for y in range(SIZE):
        for x in range(SIZE):
            # Diagonal ramp: 0 at top-left, 1 at bottom-right.
            t = (x + y) / (2.0 * (SIZE - 1))
            pixels[x, y] = (
                round(NAVY[0] + (BLUE[0] - NAVY[0]) * t),
                round(NAVY[1] + (BLUE[1] - NAVY[1]) * t),
                round(NAVY[2] + (BLUE[2] - NAVY[2]) * t),
            )
    return base


def _draw_mark(image: Image.Image) -> None:
    """A clean 'T' monogram.

    Deliberately just the letterform: an app icon is read at ~60pt on a home
    screen, where a second element (an export chevron was tried) collapses
    into noise and reads as a smudge against the stem. Geometry is
    proportional to SIZE and optically centred — a T's visual centre of mass
    sits above its geometric one, so the mark is nudged down a little to stop
    it looking top-heavy inside the iOS corner mask.
    """
    draw = ImageDraw.Draw(image)
    cx = SIZE // 2
    optical_offset = int(SIZE * 0.015)

    bar_w = int(SIZE * 0.52)
    bar_h = int(SIZE * 0.105)
    bar_top = int(SIZE * 0.295) + optical_offset
    draw.rounded_rectangle(
        [cx - bar_w // 2, bar_top, cx + bar_w // 2, bar_top + bar_h],
        radius=bar_h // 2, fill=WHITE,
    )

    stem_w = int(SIZE * 0.105)
    stem_bottom = int(SIZE * 0.725) + optical_offset
    draw.rounded_rectangle(
        [cx - stem_w // 2, bar_top, cx + stem_w // 2, stem_bottom],
        radius=stem_w // 2, fill=WHITE,
    )


def main() -> None:
    icon = _gradient()
    _draw_mark(icon)
    assert icon.mode == "RGB", "an app icon must not carry an alpha channel"
    assert icon.size == (SIZE, SIZE)
    out = "TaliaExporter/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    icon.save(out, "PNG")
    print(f"wrote {out} ({SIZE}x{SIZE}, mode={icon.mode})")


if __name__ == "__main__":
    main()
