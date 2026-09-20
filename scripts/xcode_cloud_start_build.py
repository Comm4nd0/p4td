"""Start Xcode Cloud's Production workflow for a git tag.

Pushing a ``v*`` tag starts nothing in Xcode Cloud — its workflows build the
branches they watch, and the Production one (the only one that distributes
to App Store Connect) has to be started for the tag. Without that, the
newest build in the release's version train is the Development workflow's,
which App Store Connect refuses to attach, and deploy-ios-release.yml dies
with "refused build N and no newer build arrived". This does the start
through the App Store Connect API, with the same key the store workflows
use (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 in the environment).

Idempotent: if the workflow already has a run for the tag's commit (queued,
running or finished), nothing is started and its number is printed, so a
re-run of the lane never queues a second archive.

Environment:
  TAG                   the tag to build (e.g. v1.12.43)
  COMMIT_SHA            the commit the tag points at (skip check if unset)
  XCODE_CLOUD_WORKFLOW  substring of the workflow's name (default "production")
  REF_WAIT_SECONDS      how long to wait for Xcode Cloud to see a fresh tag
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
TAG = os.environ["TAG"]
COMMIT_SHA = (os.environ.get("COMMIT_SHA") or "").lower()
WORKFLOW_MATCH = os.environ.get("XCODE_CLOUD_WORKFLOW", "production").lower()
REF_WAIT_SECONDS = int(os.environ.get("REF_WAIT_SECONDS", "300"))

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


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path if path.startswith("/") else path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} for {method} {path}\n{e.read().decode(errors='replace')}")


def attr(item, name, default=None):
    return (item.get("attributes") or {}).get(name, default)


def paged(path):
    while path:
        page = call("GET", path)
        yield from page.get("data", [])
        path = (page.get("links") or {}).get("next")


def set_output(name, value):
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"{name}={value}\n")


# 1. The Production workflow. Match by name first; failing that, the enabled
#    workflow that has a tag start condition at all.
products = call("GET", "/v1/ciProducts").get("data", [])
if not products:
    sys.exit("No Xcode Cloud products visible to this API key.")
candidates = []
for product in products:
    for wf in paged(f"/v1/ciProducts/{product['id']}/workflows?limit=200"):
        candidates.append((product, wf))
if not candidates:
    sys.exit("No Xcode Cloud workflows found.")

by_name = [c for c in candidates if WORKFLOW_MATCH in (attr(c[1], "name") or "").lower()]
by_tag = [
    c for c in candidates
    if attr(c[1], "isEnabled") and (attr(c[1], "tagStartCondition") or attr(c[1], "manualTagStartCondition"))
]
chosen = (by_name or by_tag)
if not chosen:
    names = ", ".join(f"'{attr(c[1], 'name')}'" for c in candidates)
    sys.exit(f"No workflow named like '{WORKFLOW_MATCH}' and none with a tag start condition. Found: {names}")
product, workflow = chosen[0]
print(f"Workflow: '{attr(workflow, 'name')}' ({workflow['id']}) on product '{attr(product, 'name')}'"
      f"{' — enabled' if attr(workflow, 'isEnabled') else ' — DISABLED'}")
if not attr(workflow, "isEnabled"):
    sys.exit("That workflow is disabled in Xcode Cloud; enable it or name another with XCODE_CLOUD_WORKFLOW.")

# 2. Already built this commit? Then there is nothing to start.
if COMMIT_SHA:
    for run in paged(f"/v1/ciWorkflows/{workflow['id']}/buildRuns?limit=50"):
        sha = str((attr(run, "sourceCommit") or {}).get("commitSha", "")).lower()
        if sha == COMMIT_SHA:
            state = attr(run, "completionStatus") or attr(run, "executionProgress")
            print(f"Build {attr(run, 'number')} already exists for {COMMIT_SHA[:10]} ({state}); not starting another.")
            set_output("build_number", attr(run, "number"))
            set_output("started", "false")
            sys.exit(0)

# 3. The tag's git reference. A tag pushed seconds ago may not be visible
#    to Xcode Cloud yet, so poll for a while.
repos = call("GET", f"/v1/ciProducts/{product['id']}/primaryRepositories").get("data", [])
if not repos:
    sys.exit("The product has no primary repository.")
repo = repos[0]
deadline = time.time() + REF_WAIT_SECONDS
ref = None
while ref is None:
    for candidate in paged(f"/v1/scmRepositories/{repo['id']}/gitReferences?limit=200"):
        if attr(candidate, "kind") == "TAG" and attr(candidate, "name") == TAG and not attr(candidate, "isDeleted"):
            ref = candidate
            break
    if ref is None:
        if time.time() > deadline:
            sys.exit(f"Xcode Cloud cannot see tag {TAG} in {attr(repo, 'ownerName')}/{attr(repo, 'repositoryName')} "
                     f"after {REF_WAIT_SECONDS}s. Is it pushed?")
        print(f"Tag {TAG} not visible to Xcode Cloud yet; waiting…")
        time.sleep(20)

# 4. Start it.
created = call("POST", "/v1/ciBuildRuns", {
    "data": {
        "type": "ciBuildRuns",
        "attributes": {},
        "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": workflow["id"]}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref["id"]}},
        },
    },
})
run = created["data"]
print(f"Started build {attr(run, 'number')} of '{attr(workflow, 'name')}' for {TAG} "
      f"({attr(run, 'executionProgress')}).")
set_output("build_number", attr(run, "number"))
set_output("started", "true")
