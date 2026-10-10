#!/usr/bin/env bash
# Downloads the AGenUI HarmonyOS HAR from the latest GitHub release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARMONY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIBS_DIR="${HARMONY_DIR}/libs"
OUTPUT="${LIBS_DIR}/agenui.har"

RELEASE_TAG="AGenUI-1.2.0.beta1"
ASSET_URL="https://github.com/AGenUI/AGenUI/releases/download/${RELEASE_TAG}/AGenUI-1.2.0-harmony.har"
EXPECTED_SHA256="1d879a003abba4bc715a2d09026204274dd1ad984f8c305c1de67d20001ab4bc"

mkdir -p "${LIBS_DIR}"

echo "Fetching AGenUI HAR (${RELEASE_TAG})..."
curl -fL --retry 3 -o "${OUTPUT}.tmp" "${ASSET_URL}"
echo "${EXPECTED_SHA256}  ${OUTPUT}.tmp" | shasum -a 256 -c -
mv "${OUTPUT}.tmp" "${OUTPUT}"
echo "Saved to ${OUTPUT}"
