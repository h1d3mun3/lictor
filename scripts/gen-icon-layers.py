#!/usr/bin/env python3
"""Generate the app icon layer SVGs under design/icon/layers/.

Every layer is plain filled geometry: no SVG filters, no stroke-dasharray, and no
strokes at all. Icon Composer rebuilds glass, shadow and glow itself, so none of that is
baked in. Geometry and colours are specified in hikitsugi.md section 4.

Angles are measured clockwise from 12 o'clock on a 1024 x 1024 canvas.
"""
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "design" / "icon" / "layers"
C = 512  # canvas centre

HEAD = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'


def write(name, body):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_text(HEAD + body + "</svg>\n")


def f(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")


def pt(r, deg):
    a = math.radians(deg)
    return C + r * math.sin(a), C - r * math.cos(a)


def annulus(r_in, r_out):
    """Full ring as a single even-odd path."""
    def circle(r):
        return f"M {f(C - r)} {C} A {f(r)} {f(r)} 0 1 1 {f(C + r)} {C} A {f(r)} {f(r)} 0 1 1 {f(C - r)} {C} Z"
    return circle(r_out) + " " + circle(r_in)


def annulus_sector(r_in, r_out, start, end):
    """Ring segment from start to end degrees, clockwise."""
    large = 1 if (end - start) > 180 else 0
    ox0, oy0 = pt(r_out, start)
    ox1, oy1 = pt(r_out, end)
    ix0, iy0 = pt(r_in, start)
    ix1, iy1 = pt(r_in, end)
    return (
        f"M {f(ox0)} {f(oy0)} A {r_out} {r_out} 0 {large} 1 {f(ox1)} {f(oy1)} "
        f"L {f(ix1)} {f(iy1)} A {r_in} {r_in} 0 {large} 0 {f(ix0)} {f(iy0)} Z"
    )


def rounded_rect(x, y, w, h, r):
    return (
        f"M {x + r} {y} H {x + w - r} A {r} {r} 0 0 1 {x + w} {y + r} V {y + h - r} "
        f"A {r} {r} 0 0 1 {x + w - r} {y + h} H {x + r} A {r} {r} 0 0 1 {x} {y + h - r} "
        f"V {y + r} A {r} {r} 0 0 1 {x + r} {y} Z"
    )


def ticks(count, r_in, r_out, width, opacity):
    step = 360 / count
    half = width / 2
    y = C - r_out
    h = r_out - r_in
    rects = "".join(
        f'  <rect x="{f(C - half)}" y="{y}" width="{width}" height="{h}" transform="rotate({f(i * step)} {C} {C})"/>\n'
        for i in range(count)
    )
    return f'<g fill="#FFFFFF" fill-opacity="{opacity}">\n{rects}</g>\n'


# 1. Brushed texture: 1 px horizontal lines every 6 px.
lines = "".join(f'  <rect x="0" y="{y}" width="1024" height="1"/>\n' for y in range(0, 1024, 6))
write("bg-brush.svg", f'<g fill="#FFFFFF" fill-opacity="0.05">\n{lines}</g>\n')

# 2. Edge hairline: the 4 px stroke on the 1016 square, outlined (outer 1020, inner 1012).
write(
    "edge.svg",
    '<path fill="#FFFFFF" fill-opacity="0.14" fill-rule="evenodd" d="'
    + rounded_rect(2, 2, 1020, 1020, 226)
    + " "
    + rounded_rect(6, 6, 1012, 1012, 222)
    + '"/>\n',
)

# 3-4. Ticks, centred on r = 384.
write("ticks-minor.svg", ticks(60, 372, 396, 3, 0.32))
write("ticks-major.svg", ticks(12, 360, 408, 8, 0.85))

# 5. Track ring: r 290, stroke 56.
write("track.svg", f'<path fill="#FFFFFF" fill-opacity="0.14" fill-rule="evenodd" d="{annulus(262, 318)}"/>\n')

# 6. Arc: r 290, stroke 52, butt caps, 0 to 240 degrees.
write("arc.svg", f'<path fill="#FF6A2E" d="{annulus_sector(264, 316, 0, 240)}"/>\n')

# 7. Arc highlight ring: r 314, stroke 3.
write(
    "ring-highlight.svg",
    f'<path fill="#FFFFFF" fill-opacity="0.4" fill-rule="evenodd" d="{annulus(312.5, 315.5)}"/>\n',
)

# 8. Lock: open shackle (centre line M436 466 V362 A76 76 0 0 1 588 362 V384, stroke 40,
#    butt caps) outlined, plus the body. Both subpaths wind clockwise, so nonzero fill unions them.
shackle = "M 416 466 V 362 A 96 96 0 0 1 608 362 V 384 H 568 V 362 A 56 56 0 0 0 456 362 V 466 Z"
body = rounded_rect(388, 456, 248, 208, 24)
write("lock.svg", f'<path fill="#FFFFFF" d="{shackle} {body}"/>\n')

# 9. Keyhole: circle r 24 at (512, 548) merged with the stem x 502..522, y 556..610, radius 2.
#    The stem edges meet the circle at y = 548 + sqrt(24^2 - 10^2).
join = 548 + math.sqrt(24 ** 2 - 10 ** 2)
write(
    "keyhole.svg",
    f'<path fill="#0E1014" fill-opacity="0.75" d="M 522 {f(join)} A 24 24 0 1 0 502 {f(join)} '
    f'V 608 Q 502 610 504 610 H 520 Q 522 610 522 608 Z"/>\n',
)

print(f"wrote {len(list(OUT.glob('*.svg')))} layers to {OUT}")
