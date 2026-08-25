"""Pull the real error messages out of the latest Xcode Cloud builds.

The Xcode Cloud UI reports distribution failures as a bare "Preparing build
for App Store Connect failed", with the underlying reason held in the build's
issue list. This asks the App Store Connect API for that list directly:
products -> recent build runs -> each run's actions -> each action's issues,
printing errors in full and only counting warnings.

Read-only (GETs against the ASC API), run by xcode-cloud-diagnose.yml with
the same API key the store workflows use. Needs ASC_KEY_ID, ASC_ISSUER_ID
and ASC_KEY_P8 in the environment.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
RUNS_TO_INSPECT = 3

token = jwt.encode(
    {
        "iss": os.environ["ASC_ISSUER_ID"],
        "iat": int(time.time()) - 60,
        "exp": int(time.time()) + 15 * 60,
        "aud": "appstoreconnect-v1",
    },
    os.environ["ASC_KEY_P8"],
    algorithm="ES256",
    headers={"kid": os.environ["ASC_KEY_ID"]},
)


def get(path):
    req = urllib.request.Request(
        API + path, headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print(f"HTTP {e.code} for GET {path}\n{body}")
        return None


def attr(item, name, default=""):
    return (item.get("attributes") or {}).get(name, default)


products = get("/v1/ciProducts")
if not products or not products.get("data"):
    sys.exit("No Xcode Cloud products visible to this API key.")

for product in products["data"]:
    print(f"\n=== Product: {attr(product, 'name')} ({product['id']}) ===")

    runs = get(f"/v1/ciProducts/{product['id']}/buildRuns?sort=-number&limit={RUNS_TO_INSPECT}")
    if runs is None:
        # Some API versions reject the sort param; fall back to client-side.
        runs = get(f"/v1/ciProducts/{product['id']}/buildRuns?limit=200")
        if runs and runs.get("data"):
            runs["data"] = sorted(
                runs["data"], key=lambda r: attr(r, "number", 0), reverse=True
            )[:RUNS_TO_INSPECT]
    if not runs or not runs.get("data"):
        print("  no build runs")
        continue

    for run in runs["data"]:
        commit = attr(run, "sourceCommit") or {}
        print(
            f"\n--- Build {attr(run, 'number')}: "
            f"{attr(run, 'completionStatus') or attr(run, 'executionProgress')} "
            f"(started {attr(run, 'startedDate')}) "
            f"commit {str(commit.get('commitSha', ''))[:10]} "
            f"\"{str(commit.get('message', '')).splitlines()[0] if commit.get('message') else ''}\" ---"
        )
        actions = get(f"/v1/ciBuildRuns/{run['id']}/actions")
        for action in (actions or {}).get("data", []):
            print(
                f"  action: {attr(action, 'name')} "
                f"[{attr(action, 'actionType')}] -> {attr(action, 'completionStatus')}"
            )
            issues = get(f"/v1/ciBuildActions/{action['id']}/issues?limit=200")
            warnings = 0
            for issue in (issues or {}).get("data", []):
                if attr(issue, "issueType") == "WARNING":
                    warnings += 1
                    continue
                src = attr(issue, "fileSource") or {}
                where = (
                    f" @ {src.get('path')}:{src.get('lineNumber')}"
                    if src.get("path")
                    else ""
                )
                print(
                    f"    [{attr(issue, 'issueType')}] "
                    f"{attr(issue, 'category')}: {attr(issue, 'message')}{where}"
                )
            if warnings:
                print(f"    ({warnings} warning(s) suppressed)")
