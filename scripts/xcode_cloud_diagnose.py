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
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
RUNS_TO_INSPECT = 3
# Log lines worth surfacing from a failed action's log bundle, and the noise
# that mentions "error" without being one.
ERROR_RE = re.compile(r"error|fail|exception|denied|invalid|missing|unable", re.I)
NOISE_RE = re.compile(r"0 errors|errorlevel|failable|Werror|error-free|no errors", re.I)
MAX_LINES_PER_FILE = 40

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


def dump_failed_action_logs(action_id):
    artifacts = get(f"/v1/ciBuildActions/{action_id}/artifacts")
    for artifact in (artifacts or {}).get("data", []):
        file_type = attr(artifact, "fileType")
        if file_type not in ("LOG_BUNDLE", "RESULT_BUNDLE"):
            continue
        detail = get(f"/v1/ciArtifacts/{artifact['id']}")
        url = (detail or {}).get("data", {}).get("attributes", {}).get("downloadUrl")
        name = attr(artifact, "fileName")
        size = attr(artifact, "fileSize")
        print(f"    artifact: {name} ({file_type}, {size} bytes)")
        if not url or file_type != "LOG_BUNDLE":
            continue
        try:
            with urllib.request.urlopen(url, timeout=300) as resp:
                blob = resp.read()
        except Exception as exc:  # noqa: BLE001 - diagnostic only
            print(f"      could not download: {exc}")
            continue
        try:
            bundle = zipfile.ZipFile(io.BytesIO(blob))
        except zipfile.BadZipFile:
            print("      (not a zip; skipping)")
            continue
        for member in bundle.namelist():
            if not member.lower().endswith((".log", ".txt", ".json")):
                continue
            try:
                text = bundle.read(member).decode(errors="replace")
            except Exception:  # noqa: BLE001
                continue
            hits = [
                line.strip()
                for line in text.splitlines()
                if ERROR_RE.search(line) and not NOISE_RE.search(line)
            ]
            if not hits:
                continue
            print(f"      -- {member}: {len(hits)} error-ish line(s) --")
            for line in hits[-MAX_LINES_PER_FILE:]:
                print(f"        {line[:400]}")


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

            # The issue list for a distribution failure is often just the
            # one-line summary; the real reason is in the action's log
            # bundle. Pull it for failed actions and surface the error lines.
            if attr(action, "completionStatus") == "FAILED":
                dump_failed_action_logs(action["id"])


