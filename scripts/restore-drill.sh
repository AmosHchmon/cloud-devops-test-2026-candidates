#!/usr/bin/env bash
# PSEUDOCODE / DRAFT - PLANNING ONLY. NOT RUN against any cloud environment.
#
# Demonstrates the core recovery commands for the "accidental deletion 10:20, found 10:35" scenario
# (see docs/solution.md, section 2). Flags and output formats must be verified with `--help`
# on the gcloud version in use before any real use.
#
# Safety: by default this script only PRINTS commands. Set EXECUTE=1 to run them (drill/staging only).
# Names, tables and columns below are placeholders/assumptions. Synthetic data only; no secrets.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID}"
SRC_INSTANCE="${SRC_INSTANCE:-survey-db}"                 # production Cloud SQL instance
CLONE_INSTANCE="${CLONE_INSTANCE:-survey-db-restore-$(date +%Y%m%d)}"
BUCKET="${BUCKET:-survey-uploads}"                        # file bucket (versioning + soft delete 7d)
# Restore point in UTC, e.g. 10:19 Israel time (UTC+2 in winter) = 08:19Z. Compute carefully.
RESTORE_POINT_UTC="${RESTORE_POINT_UTC:?set RESTORE_POINT_UTC like 2026-01-01T08:19:00Z}"
DELETE_WINDOW_START_UTC="${DELETE_WINDOW_START_UTC:?e.g. 2026-01-01T08:20:00Z}"
DELETE_WINDOW_END_UTC="${DELETE_WINDOW_END_UTC:?e.g. 2026-01-01T08:35:00Z}"

run() { echo "+ $*"; if [ "${EXECUTE:-0}" = "1" ]; then "$@"; fi; }

echo "== 0. Preconditions (should already be configured; see 'Backup configuration') =="
run gcloud sql instances describe "$SRC_INSTANCE" \
  --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.availabilityType)"
run gcloud sql instances get-latest-recovery-time "$SRC_INSTANCE"

echo "== 1. Safety: on-demand backup of the CURRENT (damaged) state before changing anything =="
run gcloud sql backups create --instance="$SRC_INSTANCE" --description="pre-recovery snapshot"

echo "== 2. Clone production to the restore point (NEW instance; production is not overwritten) =="
run gcloud sql instances clone "$SRC_INSTANCE" "$CLONE_INSTANCE" \
  --point-in-time="$RESTORE_POINT_UTC"
run gcloud sql instances describe "$CLONE_INSTANCE" --format="value(state,ipAddresses)"

echo "== 3. Find the deleted rows (compare clone at 10:19 with production now) =="
# Pseudocode: export what existed at 10:19 from the clone, load into a scratch schema on production,
# then re-insert only the rows that are missing. Parents before children (foreign keys).
cat <<'SQL'
-- On the CLONE (read only):   \copy (SELECT * FROM public.surveys) TO 'surveys_clone.csv' CSV HEADER
--                             \copy (SELECT * FROM public.uploads) TO 'uploads_clone.csv' CSV HEADER
-- On PRODUCTION:
--   CREATE SCHEMA recovery;
--   CREATE TABLE recovery.surveys (LIKE public.surveys INCLUDING ALL);
--   CREATE TABLE recovery.uploads (LIKE public.uploads INCLUDING ALL);
--   \copy recovery.surveys FROM 'surveys_clone.csv' CSV HEADER
--   \copy recovery.uploads FROM 'uploads_clone.csv' CSV HEADER
--   BEGIN;
--   INSERT INTO public.surveys SELECT r.* FROM recovery.surveys r
--     WHERE NOT EXISTS (SELECT 1 FROM public.surveys p WHERE p.id = r.id);
--   INSERT INTO public.uploads SELECT r.* FROM recovery.uploads r
--     WHERE NOT EXISTS (SELECT 1 FROM public.uploads p WHERE p.id = r.id);
--   -- check row counts here, then COMMIT (or ROLLBACK)
SQL

echo "== 4. Restore deleted objects (soft delete / versioning) =="
# List what was deleted in the incident window (soft-deleted objects).
run gcloud storage ls --soft-deleted --long "gs://$BUCKET/**"
# Restore objects deleted in the window. Do NOT overwrite live objects.
run gcloud storage restore "gs://$BUCKET/**" \
  --deleted-after-time="$DELETE_WINDOW_START_UTC" \
  --deleted-before-time="$DELETE_WINDOW_END_UTC"
# Alternative for a single object (if versioning kept a non-current version):
#   gcloud storage cp "gs://$BUCKET/OBJECT#GENERATION" "gs://$BUCKET/OBJECT"

echo "== 5. Consistency checks (see docs/solution.md) =="
cat <<'SQL'
-- Export all object names referenced by the DB, then compare with the bucket listing:
--   \copy (SELECT object_name FROM public.uploads ORDER BY 1) TO 'db_objects.txt'
-- shell:
--   gcloud storage ls "gs://$BUCKET/**" | sed "s#gs://$BUCKET/##" | sort > bucket_objects.txt
--   comm -23 db_objects.txt bucket_objects.txt   # in DB but missing in bucket  -> must be empty
--   comm -13 db_objects.txt bucket_objects.txt   # in bucket but not in DB      -> review, never auto-delete
SQL

echo "== 6. Cleanup (after sign-off, not before) =="
echo "# DROP SCHEMA recovery CASCADE;   -- on production"
run gcloud sql instances delete "$CLONE_INSTANCE" --quiet
