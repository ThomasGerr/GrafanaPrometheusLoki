#!/usr/bin/env python3
"""
Create and update Grafana Orgs, users, data sources and dashboards.

Grafana cannot provision Orgs from YAML, so this drives the HTTP API instead.
It is idempotent: run it after every `make generate`, or any time you add a
client or a dashboard.

Standard library only — no pip install, no container needed.

  GRAFANA_URL=https://monitor.example.com \\
  GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD=... \\
  python3 scripts/bootstrap_grafana.py

WHY ORGS: data source permissions are a Grafana Enterprise feature. In OSS the
Org is the only boundary a Viewer cannot cross — teams and folder permissions
do not stop someone opening Explore and querying whatever they like. Each
client Org therefore gets its own data sources, pointed at that client's
prom-label-proxy, which pins `client="<id>"` into every query server-side.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ORGS_FILE = ROOT / "generated" / "grafana-orgs.json"
DASHBOARD_DIR = ROOT / "config" / "grafana" / "dashboards"

# Dashboards used to live in one folder; they are in Resources, Security and
# System now, and the old one is removed once it is empty.
OLD_FOLDER_TITLE = "Monitoring"
MAIN_ORG_ID = 1


# ── tiny HTTP client ───────────────────────────────────────────────────────

class Grafana:
    def __init__(self, url: str, user: str, password: str):
        self.url = url.rstrip("/")
        self.user = user
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            # urllib's default User-Agent is "Python-urllib/3.x", which
            # Cloudflare's bot rules reject outright with a 403 error 1010
            # ("browser signature banned") before the request reaches Grafana.
            "User-Agent": "ethic-monitor-bootstrap/1",
        }

    def call(self, method: str, path: str, body=None, ok_statuses=()):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.url + path, data=data, headers=self.headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code in ok_statuses:
                return None
            detail = e.read().decode()[:400]
            hint = ""
            if e.code == 403 and "cloudflare" in detail.lower():
                hint = (
                    "\n\nThis is Cloudflare in front of Grafana, not Grafana itself.\n"
                    "On the monitoring host, skip the public URL entirely:\n"
                    "  make bootstrap-server\n"
                    "which talks to the container over the internal network."
                )
            raise SystemExit(f"Grafana {method} {path} failed: {e.code} {detail}{hint}")
        except urllib.error.URLError as e:
            raise SystemExit(
                f"Cannot reach Grafana at {self.url}: {e.reason}\n"
                f"On the monitoring host, run `make bootstrap-server` — the stack\n"
                f"publishes no ports, so Grafana is only reachable on its own\n"
                f"Docker network. From elsewhere, set GRAFANA_URL to the public URL."
            )

    def get(self, path, **kw):
        return self.call("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.call("POST", path, body, **kw)

    def put(self, path, body=None, **kw):
        return self.call("PUT", path, body, **kw)

    def delete(self, path, **kw):
        return self.call("DELETE", path, **kw)


# ── org / user / datasource / dashboard operations ─────────────────────────

def ensure_org(gf: Grafana, name: str) -> int:
    existing = gf.get(f"/api/orgs/name/{urllib.parse.quote(name)}", ok_statuses=(404,))
    if existing:
        return existing["id"]
    created = gf.post("/api/orgs", {"name": name})
    print(f"    created Org '{name}' (id {created['orgId']})")
    return created["orgId"]


def switch_org(gf: Grafana, org_id: int) -> None:
    """
    Data source and dashboard endpoints act on the caller's *current* Org,
    so the admin has to join and switch into each client Org in turn.
    """
    gf.post(f"/api/orgs/{org_id}/users", {"loginOrEmail": gf.user, "role": "Admin"},
            ok_statuses=(409, 400))
    gf.post(f"/api/user/using/{org_id}")


def ensure_datasource(gf: Grafana, payload: dict) -> None:
    uid = payload["uid"]
    existing = gf.get(f"/api/datasources/uid/{uid}", ok_statuses=(404,))
    if existing:
        # secureJsonData is write-only, so PUT always re-sends the header value.
        gf.put(f"/api/datasources/uid/{uid}", {**payload, "id": existing["id"]})
        print(f"    updated data source '{payload['name']}'")
    else:
        gf.post("/api/datasources", payload)
        print(f"    created data source '{payload['name']}'")


def ensure_folder(gf: Grafana, title: str) -> str:
    for f in gf.get("/api/folders") or []:
        if f["title"] == title:
            return f["uid"]
    created = gf.post("/api/folders", {"title": title})
    return created["uid"]


# Panels that drive the backup API. They only work in the admin Org, which is
# the only one with that data source, and only you may start a restore — so
# they are taken out of the copy each client Org gets.
ADMIN_DATASOURCE = "backups"


def is_admin_panel(panel: dict) -> bool:
    if panel.get("type") == "row" and panel.get("title", "").endswith("(admin)"):
        return True
    sources = [panel.get("datasource")] + [t.get("datasource") for t in panel.get("targets", [])]
    return any(isinstance(s, dict) and s.get("uid") == ADMIN_DATASOURCE for s in sources)


def without_admin_panels(dash: dict) -> dict:
    """The same dashboard with the admin-only band removed and the gap closed."""
    admin = [p for p in dash.get("panels", []) if is_admin_panel(p)]
    if not admin:
        return dash
    top = min(p["gridPos"]["y"] for p in admin)
    bottom = max(p["gridPos"]["y"] + p["gridPos"]["h"] for p in admin)
    kept = [p for p in dash["panels"] if not is_admin_panel(p)]
    for p in kept:
        if p["gridPos"]["y"] >= bottom:
            p["gridPos"]["y"] -= bottom - top
    return {**dash, "panels": kept}


def push_dashboards(gf: Grafana, admin_org: bool = False) -> None:
    """One Grafana folder per directory, the same as provisioning does."""
    folders: dict[str, str] = {}
    paths = sorted(DASHBOARD_DIR.glob("*/*.json"))
    for path in paths:
        folder = path.parent.name
        if folder not in folders:
            folders[folder] = ensure_folder(gf, folder)
        dash = json.loads(path.read_text())
        if not admin_org:
            dash = without_admin_panels(dash)
        # Let Grafana own the version counter, or repeat runs collide.
        dash.pop("version", None)
        dash.pop("id", None)
        gf.post("/api/dashboards/db", {
            "dashboard": dash,
            "folderUid": folders[folder],
            "overwrite": True,
            "message": "bootstrap_grafana.py",
        })
    print(f"    pushed {len(paths)} dashboards into {', '.join(sorted(folders))}")
    remove_old_folder(gf)


def remove_old_folder(gf: Grafana) -> None:
    """Deletes the folder dashboards used to live in, but only if it is empty."""
    folder = next((f for f in gf.get("/api/folders") or []
                   if f["title"] == OLD_FOLDER_TITLE), None)
    if not folder:
        return
    left = gf.get(f"/api/search?folderUIDs={folder['uid']}&type=dash-db") or []
    if left:
        print(f"    left {OLD_FOLDER_TITLE} alone: it still holds {len(left)} dashboard(s)")
        return
    gf.delete(f"/api/folders/{folder['uid']}")
    print(f"    removed the empty {OLD_FOLDER_TITLE} folder")


def ensure_user(gf: Grafana, org_id: int, user: dict) -> str | None:
    """Returns a generated password if the user is new, otherwise None."""
    login = user["login"]
    existing = gf.get(
        f"/api/users/lookup?loginOrEmail={urllib.parse.quote(login)}", ok_statuses=(404,)
    )

    password = None
    if existing:
        user_id = existing["id"]
    else:
        password = secrets.token_urlsafe(12)
        created = gf.post("/api/admin/users", {
            "name": user.get("name", login),
            "email": user["email"],
            "login": login,
            "password": password,
            "OrgId": org_id,
        })
        user_id = created["id"]

    # Viewer, never Editor: a client editing a dashboard can rewrite its
    # queries, and in Explore they could go looking beyond it.
    gf.post(f"/api/orgs/{org_id}/users", {"loginOrEmail": login, "role": "Viewer"},
            ok_statuses=(409, 400))
    # Make the client Org their landing place.
    gf.post(f"/api/users/{user_id}/using/{org_id}", ok_statuses=(404,))

    # CRITICAL: Grafana auto-assigns new users to the Main Org. Left there, a
    # client could switch Orgs in the UI and query the admin data sources,
    # which see every tenant. Remove them.
    removed = gf.delete(f"/api/orgs/{MAIN_ORG_ID}/users/{user_id}", ok_statuses=(404, 400))
    if removed is not None:
        print(f"    removed '{login}' from the Main Org (tenant isolation)")

    return password


# ── main ───────────────────────────────────────────────────────────────────

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


def main() -> None:
    load_env_file()

    # Deliberately not GRAFANA_ROOT_URL: .env carries the public URL, and a
    # plain `make bootstrap` against `make up` must stay on localhost.
    url = os.environ.get("GRAFANA_URL") or "http://localhost:3000"
    admin_user = os.environ.get("GRAFANA_ADMIN_USER") or os.environ.get("GF_SECURITY_ADMIN_USER", "admin")
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD") or os.environ.get("GF_SECURITY_ADMIN_PASSWORD")

    if not password:
        raise SystemExit(
            "Set GF_SECURITY_ADMIN_PASSWORD (or GRAFANA_ADMIN_PASSWORD).\n"
            "Locally it is read from .env automatically."
        )
    if not ORGS_FILE.exists():
        raise SystemExit(f"{ORGS_FILE} missing — run `make generate` first.")

    gf = Grafana(url, admin_user, password)
    data = json.loads(ORGS_FILE.read_text())

    health = gf.get("/api/health")
    print(f"Grafana {health.get('version', '?')} at {url}\n")

    new_passwords: list[tuple[str, str, str]] = []

    # ── Admin Org: the fleet-wide view ──────────────────────────────────
    print("Main Org (your fleet-wide view)")
    switch_org(gf, MAIN_ORG_ID)
    push_dashboards(gf, admin_org=True)

    # ── One Org per client ──────────────────────────────────────────────
    for client in data["clients"]:
        cid, name = client["id"], client["name"]
        print(f"\n{name}  (client={cid})")

        org_id = ensure_org(gf, name)
        switch_org(gf, org_id)

        ensure_datasource(gf, {
            "name": "Prometheus",
            "uid": "prometheus",
            "type": "prometheus",
            "access": "proxy",
            # Not Prometheus directly: the label proxy pins client="<id>" into
            # every query, so this Org cannot see another client's metrics
            # even through hand-written PromQL in Explore.
            "url": f"http://prom-label-proxy-{cid}:8080",
            "isDefault": True,
            "jsonData": {"timeInterval": "30s", "httpMethod": "POST"},
        })

        ensure_datasource(gf, {
            "name": "Loki",
            "uid": "loki",
            "type": "loki",
            "access": "proxy",
            "url": "http://loki:3100",
            "jsonData": {
                "timeout": 60,
                "maxLines": 5000,
                # Loki's own multi-tenancy. This Org can only read this tenant.
                "httpHeaderName1": "X-Scope-OrgID",
            },
            "secureJsonData": {"httpHeaderValue1": cid},
        })

        push_dashboards(gf)

        for user in client["users"]:
            pw = ensure_user(gf, org_id, user)
            if pw:
                new_passwords.append((name, user["login"], pw))
            else:
                print(f"    user '{user['login']}' already exists — password unchanged")

    # Leave the admin session where it started.
    gf.post(f"/api/user/using/{MAIN_ORG_ID}")

    print("\n" + "=" * 70)
    if new_passwords:
        print("NEW LOGINS — shown once, not stored anywhere. Send them securely.")
        print("=" * 70)
        for org, login, pw in new_passwords:
            print(f"  {org}\n    username: {login}\n    password: {pw}\n")
        print("Ask each user to change their password on first login.")
    else:
        print("No new users. Existing passwords are untouched.")
    print("=" * 70)


if __name__ == "__main__":
    main()
