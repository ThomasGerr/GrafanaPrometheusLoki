#!/usr/bin/env python3
"""
Export dashboard panels as PNG images, once per client.

Run through `make render`, which starts the image renderer for the duration of
the run and removes it afterwards — nothing idles between runs. The panels are
listed in config/render/panels.json; images land in
renders/<client>/<date>/<name>.png.

  make render                          # every client, last 7 days
  make render C=acme FROM=now-30d      # one client, last 30 days

Everything is rendered from the admin Org with `var-client` set, so each image
is scoped only by the dashboard's own `client="$client"` filter. Every
dashboard in this repo filters on it; a panel added later must too, or its
image would show every tenant's data.

Standard library only, like bootstrap_grafana.py.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ORGS_FILE = ROOT / "generated" / "grafana-orgs.json"
PANELS_FILE = ROOT / "config" / "render" / "panels.json"
DASHBOARD_DIR = ROOT / "config" / "grafana" / "dashboards"
OUT_DIR = ROOT / "renders"

MAIN_ORG_ID = 1
RENDERER_STARTUP_TIMEOUT = 60  # seconds; Chromium is not started until a render


def load_env_file() -> None:
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def wait_for_renderer(url: str) -> None:
    """The renderer container was started a moment ago; give it time to listen."""
    deadline = time.monotonic() + RENDERER_STARTUP_TIMEOUT
    while True:
        try:
            with urllib.request.urlopen(f"{url}/healthz", timeout=5) as resp:
                if resp.status == 200:
                    return
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            pass
        if time.monotonic() > deadline:
            raise SystemExit(
                f"Image renderer at {url} did not come up within "
                f"{RENDERER_STARTUP_TIMEOUT}s. Run it through `make render`, which "
                f"starts it first."
            )
        time.sleep(1)


def all_value_vars(dashboard_uid: str) -> dict[str, str]:
    """
    Multi-value variables (Host, Site, Source) start with no selection, and a
    render with nothing selected picks whatever Grafana lists first. Ask for
    All explicitly so an image covers every host, not an arbitrary one.
    """
    for path in DASHBOARD_DIR.glob("*/*.json"):
        dash = json.loads(path.read_text())
        if dash.get("uid") == dashboard_uid:
            return {
                f"var-{v['name']}": "$__all"
                for v in dash.get("templating", {}).get("list", [])
                if v.get("includeAll")
            }
    raise SystemExit(f"No dashboard with uid '{dashboard_uid}' in {DASHBOARD_DIR}")


def render(grafana: str, auth: str, path: str, params: dict[str, str]) -> bytes:
    url = f"{grafana}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={
        "Authorization": auth,
        "User-Agent": "ethic-monitor-render/1",
    })
    try:
        # Grafana waits for the renderer, which waits for every query in the
        # panel; the render's own timeout (params["timeout"]) is the real limit.
        with urllib.request.urlopen(req, timeout=int(params["timeout"]) + 30) as resp:
            body = resp.read()
            if not resp.headers.get("Content-Type", "").startswith("image/"):
                raise SystemExit(f"Expected an image from {path}, got "
                                 f"{resp.headers.get('Content-Type')}: {body[:200]!r}")
            return body
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Render {path} failed: {e.code} {e.read().decode()[:400]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", help="one client id (default: every client)")
    parser.add_argument("--from", dest="time_from", default="now-7d")
    parser.add_argument("--to", dest="time_to", default="now")
    args = parser.parse_args()

    load_env_file()
    grafana = (os.environ.get("GRAFANA_URL") or "http://grafana:3000").rstrip("/")
    renderer = (os.environ.get("RENDERER_URL") or "http://em-renderer:8081").rstrip("/")
    user = os.environ.get("GRAFANA_ADMIN_USER") or os.environ.get("GF_SECURITY_ADMIN_USER", "admin")
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD") or os.environ.get("GF_SECURITY_ADMIN_PASSWORD")
    if not password:
        raise SystemExit("Set GF_SECURITY_ADMIN_PASSWORD (or GRAFANA_ADMIN_PASSWORD).")
    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    clients = [c["id"] for c in json.loads(ORGS_FILE.read_text())["clients"]]
    if args.client:
        if args.client not in clients:
            raise SystemExit(f"Unknown client '{args.client}'. Known: {', '.join(clients)}")
        clients = [args.client]

    spec = json.loads(PANELS_FILE.read_text())
    wait_for_renderer(renderer)

    today = datetime.date.today().isoformat()
    # One image at a time. Each render is its own Chromium; running them in
    # parallel is what would push a small VPS into the OOM killer.
    for client in clients:
        out = OUT_DIR / client / today
        out.mkdir(parents=True, exist_ok=True)
        for panel in spec["panels"]:
            params = {
                "orgId": str(MAIN_ORG_ID),
                "panelId": str(panel["panel"]),
                "from": args.time_from,
                "to": args.time_to,
                "width": str(panel.get("width", spec["width"])),
                "height": str(panel.get("height", spec["height"])),
                "tz": spec["timezone"],
                "timeout": "60",
                "var-client": client,
                **all_value_vars(panel["dashboard"]),
            }
            png = render(grafana, auth, f"/render/d-solo/{panel['dashboard']}/_", params)
            target = out / f"{panel['name']}.png"
            target.write_bytes(png)
            print(f"  {target.relative_to(ROOT)}  ({len(png) // 1024} KB)")

    print(f"\nDone. {len(clients) * len(spec['panels'])} images under {OUT_DIR.relative_to(ROOT)}/")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
