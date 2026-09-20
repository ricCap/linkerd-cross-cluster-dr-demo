#!/usr/bin/env python3
"""Render every .excalidraw scene in this directory to an .svg beside it.

    python3 diagrams/render-svg.py

The SVGs exist so the figures show up in README.md: GitHub will not render an
.excalidraw file, so without them a reader browsing the repo sees no diagrams at
all. The scenes stay the source of truth -- edit those, then re-run this.

WHAT THIS IS NOT

It is not Excalidraw's own exporter. It draws every shape at its exact position,
size and colour, which is what a figure needs to be read correctly, but it draws
`roughness: 1` shapes as clean geometry rather than with the hand-drawn wobble.
The cluster bands are the visible difference. If that matters, export from
Excalidraw and overwrite the .svg by hand -- README.md references the files, not
this script, so a hand-made export drops straight in.

Stdlib only, and it never writes to a .excalidraw.
"""
import base64
import html
import json
import math
import pathlib
import sys

FONTS = {
    1: "Virgil, Segoe UI Emoji, Comic Sans MS, cursive",
    2: "Helvetica, Arial, sans-serif",
    3: "Cascadia, Consolas, Menlo, monospace",
    5: "Excalifont, Virgil, Comic Sans MS, cursive",
}
PAD = 16


def esc(s):
    return html.escape(s, quote=True)


def extent(e):
    """Absolute x/y extents, following `points` for lines and arrows."""
    x, y = e.get("x", 0), e.get("y", 0)
    if e.get("points"):
        xs = [x + p[0] for p in e["points"]]
        ys = [y + p[1] for p in e["points"]]
        return min(xs), min(ys), max(xs), max(ys)
    return x, y, x + e.get("width", 0), y + e.get("height", 0)


def curve_path(pts):
    """Catmull-Rom through the points, as cubic beziers.

    Excalidraw draws a multi-point line with roundness type 2 as a curve, so a
    polyline here would show corners the editor does not.
    """
    d = f"M {pts[0][0]},{pts[0][1]}"
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[0]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else pts[-1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C {c1[0]},{c1[1]} {c2[0]},{c2[1]} {p2[0]},{p2[1]}"
    return d


def arrowhead(tip, prev, stroke, sw):
    ang = math.atan2(tip[1] - prev[1], tip[0] - prev[0])
    out = []
    for s in (0.65, -0.65):
        out.append(
            f'<line x1="{tip[0]}" y1="{tip[1]}" '
            f'x2="{tip[0] - 9 * math.cos(ang - s)}" '
            f'y2="{tip[1] - 9 * math.sin(ang - s)}" '
            f'stroke="{stroke}" stroke-width="{sw}" stroke-linecap="round"/>'
        )
    return out


def png_size(data_url):
    """Intrinsic pixel size from a PNG's IHDR, for the symbol's viewBox."""
    try:
        raw = base64.b64decode(data_url.split(",", 1)[1])
        if raw[12:16] == b"IHDR":
            return (int.from_bytes(raw[16:20], "big"),
                    int.from_bytes(raw[20:24], "big"))
    except Exception:
        pass
    return None


def render(path):
    d = json.loads(path.read_text())
    els = [e for e in d["elements"] if not e.get("isDeleted")]
    if not els:
        return None
    files = d.get("files") or {}

    box = [extent(e) for e in els]
    x0 = min(b[0] for b in box) - PAD
    y0 = min(b[1] for b in box) - PAD
    x1 = max(b[2] for b in box) + PAD
    y1 = max(b[3] for b in box) + PAD
    w, h = x1 - x0, y1 - y0

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'viewBox="{x0:.0f} {y0:.0f} {w:.0f} {h:.0f}" width="{w:.0f}" height="{h:.0f}">',
        f'<rect x="{x0:.0f}" y="{y0:.0f}" width="{w:.0f}" height="{h:.0f}" fill="#ffffff"/>',
    ]

    # One <symbol> per distinct image, referenced by <use>. Inlining the dataURL
    # at every image element instead turned a 350KB scene into a 2.4MB SVG: the
    # node icon alone appears nine times in some figures.
    used = {e.get("fileId") for e in els if e.get("type") == "image"}
    symbols = {}
    for fid in sorted(f for f in used if f in files):
        url = files[fid].get("dataURL", "")
        if not url:
            continue
        iw, ih = png_size(url) or (100, 100)
        sid = f"img{len(symbols)}"
        symbols[fid] = sid
        out.append(f'<defs><symbol id="{sid}" viewBox="0 0 {iw} {ih}">'
                   f'<image xlink:href="{url}" width="{iw}" height="{ih}"/>'
                   f'</symbol></defs>')

    for e in els:
        t = e.get("type")
        x, y = e.get("x", 0), e.get("y", 0)
        ew, eh = e.get("width", 0), e.get("height", 0)
        stroke = e.get("strokeColor", "#1e1e1e")
        bg = e.get("backgroundColor", "transparent")
        bg = "none" if bg in ("transparent", None) else bg
        sw = e.get("strokeWidth", 1)
        style = e.get("strokeStyle")
        dash = ' stroke-dasharray="8 6"' if style == "dashed" else (
            ' stroke-dasharray="2 4"' if style == "dotted" else "")
        op = e.get("opacity", 100) / 100
        fade = "" if op >= 1 else f' opacity="{op:.2f}"'

        if t == "rectangle":
            r = 6 if e.get("roundness") else 0
            out.append(f'<rect x="{x}" y="{y}" width="{ew}" height="{eh}" rx="{r}" '
                       f'fill="{bg}" stroke="{stroke}" stroke-width="{sw}"{dash}{fade}/>')
        elif t == "ellipse":
            out.append(f'<ellipse cx="{x + ew / 2}" cy="{y + eh / 2}" rx="{ew / 2}" '
                       f'ry="{eh / 2}" fill="{bg}" stroke="{stroke}" '
                       f'stroke-width="{sw}"{dash}{fade}/>')
        elif t == "diamond":
            pts = (f"{x + ew / 2},{y} {x + ew},{y + eh / 2} "
                   f"{x + ew / 2},{y + eh} {x},{y + eh / 2}")
            out.append(f'<polygon points="{pts}" fill="{bg}" stroke="{stroke}" '
                       f'stroke-width="{sw}"{dash}{fade}/>')
        elif t in ("line", "arrow", "freedraw", "draw"):
            pts = [(x + p[0], y + p[1]) for p in (e.get("points") or [])]
            if len(pts) < 2:
                continue
            if len(pts) > 2 and (e.get("roundness") or {}).get("type") == 2:
                out.append(f'<path d="{curve_path(pts)}" fill="none" stroke="{stroke}" '
                           f'stroke-width="{sw}" stroke-linecap="round"{dash}{fade}/>')
            else:
                pp = " ".join(f"{a},{b}" for a, b in pts)
                out.append(f'<polyline points="{pp}" fill="none" stroke="{stroke}" '
                           f'stroke-width="{sw}" stroke-linecap="round"{dash}{fade}/>')
            if t == "arrow":
                if e.get("endArrowhead"):
                    out += arrowhead(pts[-1], pts[-2], stroke, sw)
                if e.get("startArrowhead"):
                    out += arrowhead(pts[0], pts[1], stroke, sw)
        elif t == "image":
            sid = symbols.get(e.get("fileId"))
            if sid:
                out.append(f'<use xlink:href="#{sid}" x="{x}" y="{y}" '
                           f'width="{ew}" height="{eh}"{fade}/>')
        elif t == "text":
            size = e.get("fontSize", 16)
            fam = FONTS.get(e.get("fontFamily"), FONTS[3])
            anchor = {"left": "start", "center": "middle",
                      "right": "end"}.get(e.get("textAlign", "left"), "start")
            tx = x if anchor == "start" else (x + ew / 2 if anchor == "middle" else x + ew)
            for i, line in enumerate((e.get("text") or "").split("\n")):
                if not line:
                    continue
                out.append(
                    f'<text x="{tx}" y="{y + size * 0.85 + i * size * 1.25}" '
                    f'font-family="{fam}" font-size="{size}" fill="{stroke}" '
                    f'text-anchor="{anchor}"{fade}>{esc(line)}</text>')

    out.append("</svg>")
    return "\n".join(out)


def main():
    here = pathlib.Path(__file__).resolve().parent
    scenes = sorted(here.glob("*.excalidraw"))
    if not scenes:
        sys.exit("no .excalidraw scenes found")
    for scene in scenes:
        svg = render(scene)
        if svg is None:
            print(f"  {scene.name}: empty, skipped")
            continue
        dest = scene.with_suffix(".svg")
        dest.write_text(svg + "\n")
        print(f"  {dest.name}  ({len(svg) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
