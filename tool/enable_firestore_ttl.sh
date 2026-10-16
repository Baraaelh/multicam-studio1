#!/usr/bin/env bash
# Enables Firestore TTL on the `expiresAt` field for every collection group
# the app writes, so data of sessions that were never ended gets deleted
# automatically (see lib/core/constants/session_lifetime.dart).
#
# TTL deletes only the expired document, not its subcollections, which is
# why every collection group below carries its own policy.
#
# Requirements: gcloud CLI, logged in with an account that can administer
# Firestore in the project. TTL deletions are billed as normal deletes.
#
# Usage: tool/enable_firestore_ttl.sh [project-id]   (default: multicam-studio)
set -euo pipefail

PROJECT="${1:-multicam-studio}"

COLLECTION_GROUPS=(
  sessions
  session_codes
  peers
  admin_candidates
  camera_candidates
  commands
  recordings
  timeline
  _clock_probes
)

for group in "${COLLECTION_GROUPS[@]}"; do
  echo "Enabling TTL on ${group}.expiresAt"
  gcloud firestore fields ttls update expiresAt \
    --collection-group="${group}" \
    --enable-ttl \
    --project="${PROJECT}" \
    --async
done

echo "Done. Check progress with:"
echo "  gcloud firestore fields ttls list --project=${PROJECT}"
