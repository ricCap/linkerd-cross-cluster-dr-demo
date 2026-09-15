#!/usr/bin/env python3
"""Rebuild all-diagrams.excalidraw by stacking the seven numbered scenes.

    python3 diagrams/build-all.py

Run it after editing any of them. The combined canvas is a convenience copy, and
a convenience copy that is maintained by hand drifts: the last reorder had to be
applied twice and verified twice because of exactly that. Generating it means
there is only ever one place to make a change.

Stdlib only, and it never touches the seven sources -- it reads them, offsets
each scene under a title, and writes the result.
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
NAMES = ["01-steady-state-topology", "02-steady-state-exposure-modes",
         "03-fm1-control-plane", "04-fm2-cluster", "05-fm3-zone-brownout",
         "06-fm4-region", "07-mode-coverage"]
GAP = 90          # vertical space between panels
TITLE_DROP = 40   # title baseline to the top of its scene


def bounds(els):
    xs, ys = [], []
    for e in els:
        x, y = e.get("x", 0), e.get("y", 0)
        if e.get("points"):
            xs += [x + p[0] for p in e["points"]]
            ys += [y + p[1] for p in e["points"]]
        else:
            xs += [x, x + e.get("width", 0)]
            ys += [y, y + e.get("height", 0)]
    return min(xs), min(ys), max(ys)


def title(s, y, i):
    return {"id": f"title{i:02d}aaaaaaaaaaaaaa"[:21], "type": "text",
            "x": 0.0, "y": float(y), "width": len(s) * 12.4, "height": 25.0,
            "angle": 0, "strokeColor": "#151a1c", "backgroundColor": "transparent",
            "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid",
            "roughness": 0, "opacity": 100, "groupIds": [], "frameId": None,
            "roundness": None, "seed": 1000 + i, "version": 1,
            "versionNonce": 2000 + i, "isDeleted": False, "boundElements": [],
            "updated": 1789312439144, "link": None, "locked": False,
            "text": s, "originalText": s, "fontSize": 20, "fontFamily": 3,
            "textAlign": "left", "verticalAlign": "top", "containerId": None,
            "lineHeight": 1.25, "autoResize": True, "index": f"a{i:04d}"}


def main():
    out, files, cursor = [], {}, 0.0
    for i, name in enumerate(NAMES):
        path = HERE / f"{name}.excalidraw"
        if not path.exists():
            sys.exit(f"missing {path}")
        d = json.loads(path.read_text())
        files.update(d.get("files") or {})
        els = [e for e in d["elements"] if not e.get("isDeleted")]
        left, top, bottom = bounds(els)

        out.append(title(name, cursor, i))
        dx, dy = -left, cursor + TITLE_DROP - top
        for e in els:
            e = dict(e)
            e["x"] = e.get("x", 0) + dx
            e["y"] = e.get("y", 0) + dy
            # ids must stay unique across the merged canvas
            e["id"] = f"{name[:2]}{e['id']}"[:24]
            out.append(e)
        cursor += TITLE_DROP + (bottom - top) + GAP

    scene = {"type": "excalidraw", "version": 2,
             "source": "diagrams/build-all.py",
             "elements": out,
             "appState": {"gridSize": 20, "gridStep": 5,
                          "gridModeEnabled": False,
                          "viewBackgroundColor": "#ffffff"},
             "files": files}
    dest = HERE / "all-diagrams.excalidraw"
    dest.write_text(json.dumps(scene, indent=2, ensure_ascii=False) + "\n")
    print(f"{dest.relative_to(HERE.parent)}: {len(out)} elements, "
          f"{len(files)} embedded file(s)")


if __name__ == "__main__":
    main()
