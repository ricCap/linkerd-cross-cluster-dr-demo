#!/usr/bin/env python3
"""Prepare grafana.com dashboards for file provisioning.

Dashboards downloaded from grafana.com are built for the *import* flow: they
declare an `__inputs` block and reference the datasource as `${DS_PROMETHEUS}`,
expecting a human to pick a datasource in the UI. File provisioning never runs
that flow, so a raw download provisions with a broken datasource and every panel
reads "Datasource ${DS_PROMETHEUS} was not found".

This rewrites them to bind directly to our federating Prometheus:

  * drop __inputs / __requires
  * replace every ${DS_PROMETHEUS} reference with our datasource uid
  * null out `id` so Grafana treats it as new
  * keep `uid` and `title` so redeploys update in place

Usage: prepare.py <datasource-uid> <src-dir> <dest-dir>
"""

import json
import pathlib
import re
import sys


def rewrite_datasource(node, uid):
    """Point every datasource reference at `uid`, whatever shape it takes."""
    if isinstance(node, dict):
        # Grafana accepts both {"datasource": "name"} and
        # {"datasource": {"type": ..., "uid": ...}}; normalise to the latter.
        if "datasource" in node:
            ds = node["datasource"]
            if isinstance(ds, str) and "DS_" in ds:
                node["datasource"] = {"type": "prometheus", "uid": uid}
            elif isinstance(ds, dict) and isinstance(ds.get("uid"), str) and "DS_" in ds["uid"]:
                node["datasource"] = {"type": "prometheus", "uid": uid}
        return {k: rewrite_datasource(v, uid) for k, v in node.items()}
    if isinstance(node, list):
        return [rewrite_datasource(v, uid) for v in node]
    return node


def resolve_variables_on_load(dash):
    """Make query template variables populate when the dashboard opens.

    Dashboards from grafana.com are built for the import flow, where a human
    picks values before anything renders. They ship `refresh: 2` ("on time range
    change") with an empty `current` and no cached `options`. Provisioned from a
    file, that combination can open with the variable still unresolved, and a
    panel filtering on `namespace=~"$client_namespace"` becomes `namespace=~""`,
    which matches nothing. Every panel then reads "No data" while the underlying
    series are all present -- indistinguishable, at a glance, from a broken
    datasource or a metric the proxy never emitted.

    Forcing `refresh: 1` ("on dashboard load") makes Grafana run the variable
    query before the first render and select a value.
    """
    for var in dash.get("templating", {}).get("list", []):
        if var.get("type") == "query":
            var["refresh"] = 1
    return dash


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)

    uid, src, dest = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    dest.mkdir(parents=True, exist_ok=True)

    for path in sorted(src.glob("*.json")):
        raw = path.read_text()

        # Catch any textual leftovers the structural pass cannot see, such as
        # datasource placeholders embedded in template variable definitions.
        raw = re.sub(r"\$\{?DS_[A-Z0-9_]+\}?", uid, raw)

        dash = json.loads(raw)
        dash.pop("__inputs", None)
        dash.pop("__requires", None)
        dash["id"] = None
        dash = rewrite_datasource(dash, uid)
        dash = resolve_variables_on_load(dash)

        out = dest / path.name
        out.write_text(json.dumps(dash, indent=1))
        print(f"  {path.name:16s} -> {dash.get('title', '?')}")


if __name__ == "__main__":
    main()
