#!/usr/bin/env bash
# DRAFT - scheduled Docker cleanup for a self-hosted CI build agent. NOT RUN in a real environment.
# Default is DRY_RUN=1 (prints commands only). The systemd service sets DRY_RUN=0.
# Install path assumed: /usr/local/bin/agent-disk-cleanup.sh (see scripts/systemd/).
# Volumes are NEVER pruned automatically (reported only). Verify docker flags with `--help`.
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-168}"      # keep anything newer than 7 days
THRESHOLD_PCT="${THRESHOLD_PCT:-70}"       # deeper cleanup only above this usage
CRITICAL_PCT="${CRITICAL_PCT:-85}"         # last resort: drop all build cache
AGENT_UNIT_GLOB="${AGENT_UNIT_GLOB:-vsts.agent.*}"

log() { logger -t agent-disk-cleanup "$*" 2>/dev/null || true; echo "$(date -Is) $*"; }
run() { log "+ $*"; if [ "$DRY_RUN" = "0" ]; then "$@"; fi; }
usage_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

# One instance at a time.
exec 9>/var/lock/agent-disk-cleanup.lock
flock -n 9 || { log "another cleanup is running; exiting"; exit 0; }

# Never clean while a pipeline job is running.
if pgrep -f 'Agent.Worker' >/dev/null; then
  log "pipeline job active (Agent.Worker); skipping this run"
  exit 0
fi

# Keep new jobs from starting mid-cleanup: stop the idle agent service(s), restart on exit.
mapfile -t UNITS < <(systemctl list-units --type=service --state=running --no-legend "$AGENT_UNIT_GLOB" | awk '{print $1}')
restart_agent() { for u in "${UNITS[@]:-}"; do [ -n "$u" ] && run systemctl start "$u"; done; }
trap restart_agent EXIT
for u in "${UNITS[@]:-}"; do [ -n "$u" ] && run systemctl stop "$u"; done

BEFORE="$(usage_pct)"
log "start: disk ${BEFORE}% used, DRY_RUN=${DRY_RUN}"

# Level 1 (always): low risk.
run docker container prune -f --filter "until=24h"
run docker image prune -f                                   # dangling images only
run docker builder prune -f --filter "until=${MAX_AGE_HOURS}h"
run journalctl --vacuum-time=14d

# Level 2 (above threshold): unused images older than MAX_AGE_HOURS.
# Note: "until" uses image CREATION time, not last use. A still-needed base image may be removed
# and will simply be pulled again on the next build (slower build, not a failure).
if [ "$(usage_pct)" -ge "$THRESHOLD_PCT" ]; then
  log "usage >= ${THRESHOLD_PCT}%: pruning unused images older than ${MAX_AGE_HOURS}h"
  run docker image prune -a -f --filter "until=${MAX_AGE_HOURS}h"
fi

# Level 3 (critical): drop all build cache (next builds are slower).
if [ "$(usage_pct)" -ge "$CRITICAL_PCT" ]; then
  log "usage >= ${CRITICAL_PCT}%: dropping ALL build cache"
  run docker builder prune -a -f
fi

# Volumes: report only (data may be needed). Review and remove by hand.
log "dangling volumes (not removed):"; docker volume ls -f dangling=true || true

log "done: disk $(usage_pct)% used (was ${BEFORE}%)"
