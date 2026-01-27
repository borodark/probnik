#!/usr/bin/env bash
set -euo pipefail

# Build complete Android release package
# Run after: build_otp.sh, build_nifs.sh

source "$(dirname "$0")/env.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${PROJECT_ROOT}/_build/prod/rel/android"
ANDROID_RELEASE="${PROJECT_ROOT}/_build/android/release"

echo "==> Building Elixir release"
cd "${PROJECT_ROOT}"
MIX_ENV=prod mix release android --overwrite

echo "==> Packaging Android release (arm64-v8a)"
rm -rf "${ANDROID_RELEASE}"
mkdir -p "${ANDROID_RELEASE}/arm64-v8a"

# Copy release lib (BEAM files)
cp -r "${RELEASE_DIR}/lib" "${ANDROID_RELEASE}/arm64-v8a/"
cp -r "${RELEASE_DIR}/releases" "${ANDROID_RELEASE}/arm64-v8a/"

# Replace x86 NIFs with ARM64 NIFs
rm -f "${ANDROID_RELEASE}/arm64-v8a/lib/scenic-"*/priv/*.so
cp "${PROJECT_ROOT}/_build/android/nifs/arm64-v8a/"*.so \
   "${ANDROID_RELEASE}/arm64-v8a/lib/scenic-"*/priv/

# Copy Android OTP (ERTS)
cp -r "${PROJECT_ROOT}/_install/android-arm64/usr/local/lib/erlang" \
   "${ANDROID_RELEASE}/arm64-v8a/erts"

# Generate manifest file for asset extraction
echo "==> Generating asset manifest"
(cd "${ANDROID_RELEASE}/arm64-v8a" && find . -type f ! -name "file_manifest.txt" | sed 's|^\./||' | sort > file_manifest.txt)

echo ""
echo "==> Android release built"
echo "    Location: ${ANDROID_RELEASE}/arm64-v8a/"
echo ""
du -sh "${ANDROID_RELEASE}/arm64-v8a/"
echo ""
echo "Files: $(wc -l < "${ANDROID_RELEASE}/arm64-v8a/file_manifest.txt") files in manifest"
