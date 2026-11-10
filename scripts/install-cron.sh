#!/usr/bin/env bash
# =============================================================================
# Install or refresh p4td's crontab entries. deploy.sh runs this after every
# healthy deploy, so the schedule in production is always the one in git.
#
#   install-cron.sh            install into the current user's crontab
#   install-cron.sh --print    read a crontab on stdin, print what would be
#                              installed, change nothing (also how it is tested)
#
# The schedule used to be installed by scripts/deploy-to-hetzner.sh — the
# laptop script — so the automatic deploy never touched it: a scheduled command
# added in a commit stayed unscheduled until someone happened to deploy by
# hand, and the backup was never scheduled at all.
#
# This box is shared with other apps, and so may be the crontab. Everything
# here is written to leave their lines exactly as they are:
#
# * p4td's entries live between two marker lines and only that block is
#   rewritten.
# * The entries the old laptop script installed (no markers) are recognised by
#   this checkout's path *and* a p4td command name, and are replaced by the
#   block — that is what makes the first run a hand-over, not a duplicate.
# * If the existing crontab cannot be read for any reason other than "there
#   isn't one", nothing is written.
# * The crontab as it was is saved to backups/crontab-<stamp>.txt first.
#
# Times are UK local time: each line fires hourly and scripts/run-cron.sh runs
# the job only in the London hour named (see that script for why).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN="bash $REPO_ROOT/scripts/run-cron.sh"

BEGIN_MARK="# >>> p4td cron - managed by scripts/install-cron.sh; edits inside are overwritten >>>"
END_MARK="# <<< p4td cron <<<"

# Commands whose unmarked crontab lines are ours to replace.
LEGACY_COMMANDS='prune_feed_media|send_vaccination_reminders|send_fleet_reminders|generate_monthly_invoices|sync_xero_invoices|send_invoice_reminders|send_compliance_reminders|send_end_of_day_alerts|send_tomorrow_changes|prune_device_tokens|prune_auth_tokens'

# The schedule. Minute, then the London hour (or "-" for no hour guard), then
# day-of-month / month / day-of-week, then run-cron.sh's arguments.
schedule() {
    cat <<'EOF'
0   08 * * *  vaccinations manage send_vaccination_reminders
5   08 * * *  fleet        manage send_fleet_reminders
10  08 * * *  compliance   manage send_compliance_reminders
0   09 * * *  invoices     manage send_invoice_reminders
30  17 * * *  eod          manage send_end_of_day_alerts
0   18 * * *  changes      manage send_tomorrow_changes
0   06 1 * *  invoices     manage generate_monthly_invoices
*/30 - * * *  xero         manage sync_xero_invoices
0   03 * * 0  prune        manage prune_feed_media --include-orphans
20  03 * * 0  tokens       manage prune_device_tokens
EOF
}

# The managed block, ready for a crontab. $1 = "1" to include the backup line.
block() {
    echo "$BEGIN_MARK"
    echo "# UK local time. Logs: /var/log/p4td-<name>.log. Change scripts/install-cron.sh, not this."
    schedule | while read -r minute hour dom month dow args; do
        [ -n "$minute" ] || continue
        # shellcheck disable=SC2086,SC2116  # collapse the table's column padding
        args="$(echo $args)"
        if [ "$hour" = "-" ]; then
            echo "$minute * $dom $month $dow $RUN $args"
        else
            echo "$minute * $dom $month $dow $RUN --london-hour $hour $args"
        fi
    done
    if [ "$1" = "1" ]; then
        echo "30 * * * * $RUN --london-hour 02 backup host bash $REPO_ROOT/scripts/backup-db.sh"
    fi
    echo "$END_MARK"
}

# stdin: an existing crontab. stdout: the same with p4td's old entries taken
# out — the managed block, and the laptop script's unmarked lines.
strip_ours() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v repo="$REPO_ROOT" -v legacy="$LEGACY_COMMANDS" '
        # True when the line names this checkout itself — not a sibling such
        # as <repo>-staging, which merely starts with the same characters.
        function names_repo(line,    at, rest) {
            rest = line
            while ((at = index(rest, repo)) > 0) {
                rest = substr(rest, at + length(repo))
                if (rest !~ /^[A-Za-z0-9_.-]/) return 1
            }
            return 0
        }
        $0 == begin { inside = 1; next }
        $0 == end   { inside = 0; next }
        inside      { next }
        # An unmarked line is ours only if it is a real entry (not a comment),
        # names this checkout, and runs one of our commands (the old laptop
        # script) or our runner (a managed line whose markers were removed).
        $0 !~ /^[[:space:]]*#/ && names_repo($0) \
            && ($0 ~ ("manage\\.py (" legacy ")([^A-Za-z0-9_]|$)") || $0 ~ /scripts\/run-cron\.sh/) { next }
        { print }
    '
}

# A backup line somebody wrote by hand (the old instructions said to) may chain
# their own off-box copy after it. Leave such a line alone and do not add ours
# beside it.
has_own_backup() {
    awk -v repo="$REPO_ROOT" '
        $0 !~ /^[[:space:]]*#/ && index($0, "backup-db.sh") && $0 !~ /run-cron\.sh/ { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

render() {
    local existing="$1" kept include_backup=1
    kept="$(printf '%s\n' "$existing" | strip_ours)"
    if printf '%s\n' "$kept" | has_own_backup; then
        include_backup=0
    fi
    # Drop trailing blank lines so repeated runs don't grow the file.
    kept="$(printf '%s\n' "$kept" | awk '{ lines[NR] = $0 } END { n = NR; while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }')"
    if [ -n "$kept" ]; then
        printf '%s\n\n' "$kept"
    fi
    block "$include_backup"
}

if [ "${1:-}" = "--print" ]; then
    render "$(cat)"
    exit 0
fi

if ! command -v crontab >/dev/null 2>&1; then
    echo "install-cron.sh: no crontab command on this host; nothing installed." >&2
    exit 1
fi

# Read what is there. "no crontab for <user>" is an empty one; any other
# failure means we do not know what is there, and must not overwrite it.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
if existing="$(crontab -l 2>"$err_file")"; then
    :
elif grep -qi 'no crontab' "$err_file"; then
    existing=""
else
    echo "install-cron.sh: could not read the current crontab; leaving it untouched:" >&2
    cat "$err_file" >&2
    exit 1
fi

new="$(render "$existing")"

if [ "$new" = "$existing" ]; then
    echo "    Crontab already up to date."
    exit 0
fi

# Keep what was there, so a mistake here is one `crontab <file>` from undone.
if [ -n "$existing" ]; then
    mkdir -p "$REPO_ROOT/backups"
    chmod 700 "$REPO_ROOT/backups"
    saved="$REPO_ROOT/backups/crontab-$(date -u +%Y%m%dT%H%M%SZ).txt"
    printf '%s\n' "$existing" > "$saved"
    echo "    Previous crontab saved to $saved"
    # shellcheck disable=SC2012  # names are ours: timestamps, no whitespace
    { ls -1t "$REPO_ROOT"/backups/crontab-*.txt 2>/dev/null || true; } | tail -n +11 | while read -r old; do
        rm -f "$old"
    done
fi

printf '%s\n' "$new" | crontab -

if printf '%s\n' "$existing" | strip_ours | has_own_backup; then
    echo "    NOTE: an existing backup-db.sh entry was left as it is; no managed backup line added."
fi
echo "    Crontab installed: $(printf '%s\n' "$new" | grep -c 'scripts/run-cron.sh') p4td entries."
