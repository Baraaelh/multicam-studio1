#!/usr/bin/env bash
# Builds the Google Play bundle: release-signed, App Check on Play Integrity.
# Needs android/key.properties (see PLAY_STORE.md). Bump `version:` in
# pubspec.yaml before every upload — Play rejects a versionCode it has seen.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f android/key.properties ]]; then
  echo "android/key.properties is missing; Play rejects debug-signed bundles." >&2
  echo "See PLAY_STORE.md, step 2." >&2
  exit 1
fi

flutter build appbundle --release --dart-define=APP_CHECK_PLAY_INTEGRITY=true

echo
echo "Upload: build/app/outputs/bundle/release/app-release.aab"
