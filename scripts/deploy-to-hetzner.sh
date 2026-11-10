#!/usr/bin/env bash
# Deploy the current `main` to production from a laptop.
#
#   HETZNER_HOST=root@<server> ./scripts/deploy-to-hetzner.sh [--no-cache]
#   ./scripts/deploy-to-hetzner.sh root@<server> [--no-cache]
#
# This is a thin wrapper: it SSHes in and runs ./deploy.sh, the same script the
# automatic deploy runs. It used to be a second implementation of the deploy —
# its own pull (without --ff-only), its own health gate, and the only place the
# crontab was ever installed — and the two drifted. Everything it did now lives
# in deploy.sh: the rollback point, the pull, the migration, the health gate,
# the scheduled jobs.
#
# The server's address is deliberately not in this file: the repository is
# public. Pass it as HETZNER_HOST or as the first argument. SSH_KEY may name an
# identity file; HETZNER_APP_DIR overrides the checkout's path.

set -euo pipefail

HETZNER_HOST="${HETZNER_HOST:-}"
if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
    HETZNER_HOST="$1"
    shift
fi

if [ -z "$HETZNER_HOST" ]; then
    echo "ERROR: no server given." >&2
    echo "Set HETZNER_HOST (e.g. HETZNER_HOST=root@<server>) or pass it as the first argument." >&2
    exit 1
fi

APP_DIR="${HETZNER_APP_DIR:-/root/p4td}"
SSH_KEY="${SSH_KEY:-}"

for arg in "$@"; do
    case "$arg" in
        --no-cache|--skip-pull) ;;
        *) echo "ERROR: unknown option '$arg' (expected --no-cache or --skip-pull)." >&2; exit 1 ;;
    esac
done

ssh_cmd=(ssh)
if [ -n "$SSH_KEY" ]; then
    ssh_cmd+=(-i "$SSH_KEY")
fi

echo "=== Deploying P4TD ==="
echo "Host: $HETZNER_HOST"
echo ""

# The options were checked against a fixed list above, so they are safe to
# place in the remote command line as they are.
"${ssh_cmd[@]}" "$HETZNER_HOST" "cd '$APP_DIR' && ./deploy.sh $*"

echo ""
echo "Done. App is live at: https://paws4thoughtdogs.com"
