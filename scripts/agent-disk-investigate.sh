#!/usr/bin/env bash
# DRAFT - READ-ONLY investigation for a full build-agent disk. NOT RUN in a real environment.
# Changes nothing. Safe to run as a sudo-capable user. See docs/solution.md, section 3.
# Tip: if the disk is 100% full some commands may fail; free a little space first
# (e.g. `sudo journalctl --vacuum-size=200M`) and re-run.
set -uo pipefail

sec() { printf '\n===== %s =====\n' "$*"; }

sec "1. Filesystem usage and inodes (inode exhaustion also gives 'No space left on device')"
df -hT /
df -i /

sec "2. Biggest top-level directories (-x: stay on this filesystem)"
sudo du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15

sec "3. /var/lib and Docker internals"
sudo du -xh --max-depth=1 /var/lib 2>/dev/null | sort -rh | head -10
sudo du -sh /var/lib/docker/* 2>/dev/null | sort -rh

sec "4. Docker's own accounting (images, containers, volumes, build cache)"
sudo docker system df
sudo docker system df -v 2>/dev/null | head -80

sec "5. Candidates (listing only)"
echo "-- images, newest first"; sudo docker images -a --format '{{.CreatedSince}}\t{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.ID}}' | head -40
echo "-- dangling images"; sudo docker images -f dangling=true -q | wc -l
echo "-- stopped containers"; sudo docker ps -a -f status=exited --format '{{.Names}}\t{{.Status}}\t{{.Image}}' | head -20
echo "-- dangling volumes"; sudo docker volume ls -f dangling=true
echo "-- largest container logs"; sudo du -h /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -rh | head -5

sec "6. Other consumers"
sudo journalctl --disk-usage
sudo du -sh /var/log /tmp /var/tmp 2>/dev/null
echo "-- deleted-but-still-open files (space not released until the process exits)"
sudo lsof +L1 2>/dev/null | head -10

sec "7. Pipeline agent workspace"
sudo du -xh --max-depth=2 /opt/ado-agent/_work 2>/dev/null | sort -rh | head -15

sec "8. Is anything running right now? (check BEFORE deleting)"
pgrep -af 'Agent.Worker' || echo "no active pipeline job (Agent.Worker not running)"
sudo docker ps --format '{{.Names}}\t{{.Image}}\t{{.RunningFor}}'
